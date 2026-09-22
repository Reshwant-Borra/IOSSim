import Darwin
import Foundation

public struct SigningBundleNode: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let bundleId: String?
    public let sha256: String?
    public let mode: UInt32?
    public let symlinkTarget: String?
}

public struct SigningBundleGraph: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let rootBundleId: String
    public let nodes: [SigningBundleNode]
    public let inventorySha256: String

    /// Inspection is discovery, not approval. Production callers must compare
    /// this to the manifest bound into EngineIntegrity before signing.
    public var expected: ExpectedSigningBundleGraph {
        ExpectedSigningBundleGraph(schemaVersion: schemaVersion, rootBundleId: rootBundleId,
            signableNodes: nodes.filter { ["bundle", "mach_o"].contains($0.kind) }.map {
                .init(relativePath: $0.relativePath, kind: $0.kind, bundleId: $0.bundleId)
            }, inventorySha256: inventorySha256)
    }
}

public struct ExpectedSigningBundleGraph: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public let relativePath: String
        public let kind: String
        public let bundleId: String?
    }
    public let schemaVersion: UInt32
    public let rootBundleId: String
    public let signableNodes: [Node]
    public let inventorySha256: String
}

public indirect enum SigningEntitlementValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), array([SigningEntitlementValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .array(try c.decode([SigningEntitlementValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

/// Public signing inputs only. PKCS#8 has no serializable field.
public struct InProcessSigningRequest: Encodable, Sendable {
    public let inputBundle: String
    public let outputBundle: String
    public let certificateChainDer: [[UInt8]]
    public let profiles: [String: [UInt8]]
    public let entitlements: [String: [String: SigningEntitlementValue]]
    public let expected: ExpectedSigningBundleGraph

    public init(inputBundle: URL, outputBundle: URL, certificateChainDER: [Data],
                profiles: [String: Data], entitlements: [String: [String: SigningEntitlementValue]],
                expected: ExpectedSigningBundleGraph) {
        self.inputBundle = inputBundle.path; self.outputBundle = outputBundle.path
        self.certificateChainDer = certificateChainDER.map { Array($0) }
        self.profiles = profiles.mapValues { Array($0) }
        self.entitlements = entitlements; self.expected = expected
    }
}

public struct InProcessSigningReceipt: Codable, Equatable, Sendable {
    public struct MachO: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sha256: String
        public let mode: UInt32
    }
    public let schemaVersion: UInt32
    public let signingCore: String
    public let inputInventorySha256: String
    public let outputInventorySha256: String
    public let rootBundleId: String
    public let verifiedMachos: [MachO]
    public let embeddedProfileBundleIds: [String]
    public let entitlementBundleIds: [String]
}

public struct InProcessVerificationReceipt: Decodable, Sendable {
    public let schemaVersion: UInt32
    public let rootBundleId: String
    public let inventorySha256: String
    public let verifiedMachos: [InProcessSigningReceipt.MachO]
}

public enum InProcessSignerFailure: Error, Equatable, Sendable {
    case libraryUnavailable, incompatibleABI, malformedResult, requestTooLarge
    case native(code: String)
}

/// Separate facade over the same packaged device bridge dylib. There is no
/// external-signing fallback. Function pointers never outlive the dlopen handle.
public final class InProcessSigner: @unchecked Sendable {
    public static let abiVersion: UInt32 = 1
    private static let maxBytes = 32 * 1024 * 1024
    private typealias ABI = @convention(c) () -> UInt32
    private typealias PathCall = @convention(c) (UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Sign = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
    private struct ResultLayout {
        let status: Int32
        let payload: UnsafePointer<UInt8>?
        let length: Int
        let diagnostic: UnsafePointer<CChar>?
    }
    private struct PathRequest: Encodable { let schemaVersion = 1; let bundlePath: String }
    private struct SignEnvelope: Encodable { let schemaVersion = 1; let request: InProcessSigningRequest }
    private struct ErrorEnvelope: Decodable { let schemaVersion: Int; let code: String }
    private let library: UnsafeMutableRawPointer
    private let inspectCall: PathCall
    private let verifyCall: PathCall
    private let signCall: Sign
    private let create: Create
    private let cancelCall: Release
    private let operationFree: Release
    private let resultFree: Release

    public convenience init(bundle: Bundle = .main) throws {
        // Production resolution uses packaged locations only. Explicit paths are
        // available through the internal initializer for integration tests.
        let paths = DynamicNativeDeviceTransport.libraryCandidates(environment: [:], bundle: bundle)
        guard let path = paths.first(where: FileManager.default.fileExists(atPath:)) else {
            throw InProcessSignerFailure.libraryUnavailable
        }
        try self.init(libraryURL: URL(fileURLWithPath: path))
    }

    init(libraryURL: URL) throws {
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw InProcessSignerFailure.libraryUnavailable }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw InProcessSignerFailure.incompatibleABI }
            return unsafeBitCast(address, to: T.self)
        }
        do {
            let abi = try symbol("veya_signing_abi_version", ABI.self)
            guard abi() == Self.abiVersion else { throw InProcessSignerFailure.incompatibleABI }
            inspectCall = try symbol("veya_signing_inspect", PathCall.self)
            verifyCall = try symbol("veya_signing_verify", PathCall.self)
            signCall = try symbol("veya_signing_sign", Sign.self)
            create = try symbol("veya_signing_operation_create", Create.self)
            cancelCall = try symbol("veya_signing_cancel", Release.self)
            operationFree = try symbol("veya_signing_operation_free", Release.self)
            resultFree = try symbol("veya_signing_result_free", Release.self)
            library = handle
        } catch { dlclose(handle); throw error }
    }
    deinit { dlclose(library) }

    public func inspect(_ bundleURL: URL) throws -> SigningBundleGraph {
        let bytes = try encode(PathRequest(bundlePath: bundleURL.path))
        return try bytes.withUnsafeBytes { try consume(inspectCall($0.bindMemory(to: UInt8.self).baseAddress, $0.count)) }
    }

    public func verify(_ bundleURL: URL) throws -> InProcessVerificationReceipt {
        let bytes = try encode(PathRequest(bundlePath: bundleURL.path))
        return try bytes.withUnsafeBytes { try consume(verifyCall($0.bindMemory(to: UInt8.self).baseAddress, $0.count)) }
    }

    public func sign(_ request: InProcessSigningRequest, keyID: String, installationID: UUID,
                     keyStore: VeyaSigningKeyStore) async throws -> InProcessSigningReceipt {
        let bytes = try encode(SignEnvelope(request: request))
        let operation = try Operation(owner: self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await keyStore.withUnlockedPKCS8(keyID: keyID, installationID: installationID) { key in
                try self.sign(bytes: bytes, key: key, operation: operation)
            }
        } onCancel: { operation.cancel() }
    }

    // Closure-only raw key entry for native qualification; no serialization or
    // logging. Production uses the key-store-scoped method above.
    func signForQualification(_ request: InProcessSigningRequest, key: UnsafeRawBufferPointer) throws -> InProcessSigningReceipt {
        try sign(bytes: encode(SignEnvelope(request: request)), key: key, operation: Operation(owner: self))
    }
    private func sign(bytes: Data, key: UnsafeRawBufferPointer, operation: Operation) throws -> InProcessSigningReceipt {
        guard (1...65536).contains(key.count) else { throw InProcessSignerFailure.requestTooLarge }
        return try bytes.withUnsafeBytes { input in
            try consume(signCall(operation.pointer, input.bindMemory(to: UInt8.self).baseAddress, input.count,
                                 key.bindMemory(to: UInt8.self).baseAddress, key.count))
        }
    }
    private func encode<T: Encodable>(_ request: T) throws -> Data {
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= Self.maxBytes else { throw InProcessSignerFailure.requestTooLarge }
        return bytes
    }
    private func consume<T: Decodable>(_ pointer: UnsafeMutableRawPointer?) throws -> T {
        guard let pointer else { throw InProcessSignerFailure.malformedResult }
        defer { resultFree(pointer) }
        let result = pointer.load(as: ResultLayout.self)
        guard (1...Self.maxBytes).contains(result.length), let payload = result.payload else { throw InProcessSignerFailure.malformedResult }
        let data = Data(bytes: payload, count: result.length)
        if result.status != 0 {
            guard let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
                  failure.schemaVersion == 1, failure.code.hasPrefix("VEYA-SIGN-"), failure.code.count <= 80 else {
                throw InProcessSignerFailure.malformedResult
            }
            throw InProcessSignerFailure.native(code: failure.code)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw InProcessSignerFailure.malformedResult }
        return decoded
    }
    private final class Operation: @unchecked Sendable {
        let owner: InProcessSigner
        let pointer: UnsafeMutableRawPointer
        init(owner: InProcessSigner) throws {
            guard let pointer = owner.create() else { throw InProcessSignerFailure.malformedResult }
            self.owner = owner; self.pointer = pointer
        }
        func cancel() { owner.cancelCall(pointer) }
        deinit { owner.operationFree(pointer) }
    }
}
