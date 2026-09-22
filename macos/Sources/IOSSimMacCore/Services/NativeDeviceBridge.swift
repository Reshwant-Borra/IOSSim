import CryptoKit
import Darwin
import Foundation

public enum DeviceConnectionKind: String, Codable, Equatable, Sendable {
    case usb
    case wireless
    case unknown
}
public enum DeviceTrustState: String, Codable, Equatable, Sendable {
    case trusted
    case missing
    case unknown
}

public enum DeviceLockState: String, Codable, Equatable, Sendable {
    case unlocked
    case locked
    case unknown
}

public enum DeveloperModeReadiness: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case requiresUserAction
    case requiresReboot
    case serviceUnavailable
    case unknown
}

/// The only model allowed to bind the different identifiers used during setup.
/// A UDID remains authoritative for the selected physical phone. Connection-
/// local and RemotePairing identifiers are metadata, never substitutes.
public struct IOSSimDeviceIdentity: Codable, Equatable, Hashable, Sendable {
    public let udid: String
    public let signingRegistrationIdentifier: String
    public let usbmuxIdentifier: UInt32?
    public let connection: DeviceConnectionKind?
    public let remotePairingIdentifier: String?
    public let developerServicesIdentifier: String?
    public let connectionGeneration: UInt64

    public init(
        udid: String,
        signingRegistrationIdentifier: String? = nil,
        usbmuxIdentifier: UInt32? = nil,
        connection: DeviceConnectionKind? = nil,
        remotePairingIdentifier: String? = nil,
        developerServicesIdentifier: String? = nil,
        connectionGeneration: UInt64 = 0
    ) throws {
        let udid = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidIdentifier(udid) else { throw NativeDeviceBridgeError.invalidIdentity }
        let signing = signingRegistrationIdentifier ?? udid
        guard Self.isValidIdentifier(signing) else { throw NativeDeviceBridgeError.invalidIdentity }
        self.udid = udid
        self.signingRegistrationIdentifier = signing
        self.usbmuxIdentifier = usbmuxIdentifier
        self.connection = connection
        self.remotePairingIdentifier = remotePairingIdentifier
        self.developerServicesIdentifier = developerServicesIdentifier
        self.connectionGeneration = connectionGeneration
    }

    public func binds(to other: IOSSimDeviceIdentity) -> Bool {
        guard udid == other.udid,
              signingRegistrationIdentifier == other.signingRegistrationIdentifier else { return false }
        if let usbmuxIdentifier, let otherMux = other.usbmuxIdentifier,
           usbmuxIdentifier != otherMux { return false }
        if let connection, let otherConnection = other.connection,
           connection != otherConnection { return false }
        return true
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        (8...256).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.")).contains($0)
            }
    }
}

public struct NativeDeviceDescriptor: Codable, Equatable, Sendable {
    public let identity: IOSSimDeviceIdentity
    public let connection: DeviceConnectionKind

    public init(identity: IOSSimDeviceIdentity, connection: DeviceConnectionKind) {
        self.identity = identity
        self.connection = connection
    }
}

public struct NativeDeviceInspection: Codable, Equatable, Sendable {
    public let identity: IOSSimDeviceIdentity
    public let connection: DeviceConnectionKind
    public let name: String?
    public let model: String?
    public let osVersion: String?
    public let osBuild: String?
    public let trust: DeviceTrustState
    public let lockState: DeviceLockState
    public let developerMode: DeveloperModeReadiness

    public init(
        identity: IOSSimDeviceIdentity,
        connection: DeviceConnectionKind,
        name: String? = nil,
        model: String? = nil,
        osVersion: String? = nil,
        osBuild: String? = nil,
        trust: DeviceTrustState = .unknown,
        lockState: DeviceLockState = .unknown,
        developerMode: DeveloperModeReadiness = .unknown
    ) {
        self.identity = identity
        self.connection = connection
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.trust = trust
        self.lockState = lockState
        self.developerMode = developerMode
    }
}

public enum LockdownPairingState: String, Codable, Equatable, Sendable {
    case noPairRecord = "NO_PAIR_RECORD"
    case pairRequested = "PAIR_REQUESTED"
    case waitingForUnlock = "WAITING_FOR_UNLOCK"
    case waitingForUserTrust = "WAITING_FOR_USER_TRUST"
    case pairRecordCreated = "PAIR_RECORD_CREATED"
    case pairRecordPersisted = "PAIR_RECORD_PERSISTED"
    case lockdownSessionValidated = "LOCKDOWN_SESSION_VALIDATED"
    case denied = "DENIED"
    case disconnected = "DISCONNECTED"
}

public struct LockdownPairingReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let state: LockdownPairingState
    public let identity: IOSSimDeviceIdentity
    public let pairRecordCreated: Bool
    public let pairRecordPersisted: Bool
    public let sessionValidated: Bool

    public init(
        schemaVersion: Int = LockdownPairingReceipt.currentSchemaVersion,
        state: LockdownPairingState,
        identity: IOSSimDeviceIdentity,
        pairRecordCreated: Bool,
        pairRecordPersisted: Bool,
        sessionValidated: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.identity = identity
        self.pairRecordCreated = pairRecordCreated
        self.pairRecordPersisted = pairRecordPersisted
        self.sessionValidated = sessionValidated
    }
}

public struct DeveloperServicesReadinessReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let coreDeviceProxyReady: Bool
    public let softwareTunnelReady: Bool
    public let rsdReady: Bool
    public let remoteXPCReady: Bool
    public let appServiceReady: Bool
    public let launchFeatureReady: Bool
    public let ddiMounted: Bool?
    public let schemaVersion: Int?
    public let deviceUDIDHash: String?
    public let usbmuxIdentifier: UInt32?
    public let connection: DeviceConnectionKind?
    public let connectionGeneration: UInt64?
    public let developerSupportIdentity: String?
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?
    public let sessionIdentifier: String?
    public let targetBundleIdentifier: String?
    public let launchReceipt: NativeLaunchReceipt?
    public let observedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case coreDeviceProxyReady
        case softwareTunnelReady
        case rsdReady
        case remoteXPCReady = "remoteXpcReady"
        case appServiceReady
        case launchFeatureReady
        case ddiMounted
        case schemaVersion, deviceUDIDHash, usbmuxIdentifier, connection, connectionGeneration
        case developerSupportIdentity, pairingGeneration, releaseIdentity, sessionIdentifier
        case targetBundleIdentifier, launchReceipt, observedAt
    }

    public init(
        coreDeviceProxyReady: Bool,
        softwareTunnelReady: Bool,
        rsdReady: Bool,
        remoteXPCReady: Bool,
        appServiceReady: Bool,
        launchFeatureReady: Bool,
        ddiMounted: Bool?,
        schemaVersion: Int? = nil,
        deviceUDIDHash: String? = nil,
        usbmuxIdentifier: UInt32? = nil,
        connection: DeviceConnectionKind? = nil,
        connectionGeneration: UInt64? = nil,
        developerSupportIdentity: String? = nil,
        pairingGeneration: UInt64? = nil,
        releaseIdentity: String? = nil,
        sessionIdentifier: String? = nil,
        targetBundleIdentifier: String? = nil,
        launchReceipt: NativeLaunchReceipt? = nil,
        observedAt: Date? = nil
    ) {
        self.coreDeviceProxyReady = coreDeviceProxyReady
        self.softwareTunnelReady = softwareTunnelReady
        self.rsdReady = rsdReady
        self.remoteXPCReady = remoteXPCReady
        self.appServiceReady = appServiceReady
        self.launchFeatureReady = launchFeatureReady
        self.ddiMounted = ddiMounted
        self.schemaVersion = schemaVersion
        self.deviceUDIDHash = deviceUDIDHash
        self.usbmuxIdentifier = usbmuxIdentifier
        self.connection = connection
        self.connectionGeneration = connectionGeneration
        self.developerSupportIdentity = developerSupportIdentity
        self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
        self.sessionIdentifier = sessionIdentifier
        self.targetBundleIdentifier = targetBundleIdentifier
        self.launchReceipt = launchReceipt
        self.observedAt = observedAt
    }

    public var transportReady: Bool {
        coreDeviceProxyReady && softwareTunnelReady && rsdReady && remoteXPCReady
            && appServiceReady && launchFeatureReady
    }

    public var ready: Bool {
        guard transportReady,
              schemaVersion == Self.currentSchemaVersion,
              let deviceUDIDHash, deviceUDIDHash.count == 64,
              usbmuxIdentifier != nil, connection != nil, connectionGeneration != nil,
              let developerSupportIdentity, !developerSupportIdentity.isEmpty,
              let releaseIdentity, !releaseIdentity.isEmpty,
              let sessionIdentifier, UUID(uuidString: sessionIdentifier) != nil,
              let targetBundleIdentifier,
              let launchReceipt,
              launchReceipt.bundleIdentifier == targetBundleIdentifier,
              launchReceipt.appServiceConnected,
              launchReceipt.pid > 0,
              observedAt != nil else { return false }
        return true
    }

    public func isCurrent(
        for device: IOSSimDeviceIdentity,
        releaseIdentity: String,
        pairingGeneration: UInt64?,
        targetBundleIdentifier: String,
        now: Date = Date(),
        maximumAge: TimeInterval = 300
    ) -> Bool {
        guard let observedAt,
              maximumAge > 0,
              observedAt <= now.addingTimeInterval(5),
              now.timeIntervalSince(observedAt) <= maximumAge else { return false }
        return ready
            && deviceUDIDHash == Self.hash(device.udid)
            && usbmuxIdentifier == device.usbmuxIdentifier
            && connection == device.connection
            && connectionGeneration == device.connectionGeneration
            && self.releaseIdentity == releaseIdentity
            && self.pairingGeneration == pairingGeneration
            && self.targetBundleIdentifier == targetBundleIdentifier
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum NativeDeviceBridgeError: Error, Equatable, Sendable {
    case libraryUnavailable
    case libraryLoadFailure(String)
    case incompatibleABI
    case invalidIdentity
    case deviceNotFound
    case deviceDisconnected
    case deviceLocked
    case trustRequired
    case developerModeRequired
    case cancelled
    case timedOut
    case decodingFailure(String)
    case protocolFailure(String)
    case internalFailure(String)
    case deviceResolutionFailed(String)
    case coreDeviceProxyFailed(String)
    case softwareTunnelFailed(String)
    case rsdUnavailable(String)
    case remoteXPCFailed(String)
    case appServiceUnavailable(String)
    case featureUnavailable(String)
    case applicationNotFound(String)
    case ddiRequired(String)
    case developerServicesNotReady(String)
    case launchRejected(String)
    case containerUnavailable(String)
    case pairingRejected(String)
    case trustPromptPending
    case trustDenied
}

public protocol NativeDeviceTransport: Sendable {
    func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor]
    func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection
}

public actor IOSSimDeviceBridge {
    private let transport: any NativeDeviceTransport
    private var generation: UInt64 = 0
    private var alternativesByUDID: [String: [NativeDeviceDescriptor]] = [:]

    public init(transport: any NativeDeviceTransport = DynamicNativeDeviceTransport()) {
        self.transport = transport
    }

    public func listDevices(timeout: Duration = .seconds(8)) async throws -> [NativeDeviceDescriptor] {
        generation &+= 1
        let observed = try await transport.listDevices(timeout: timeout)
        var candidatesByUDID: [String: [NativeDeviceDescriptor]] = [:]
        for candidate in observed {
            let identity = try IOSSimDeviceIdentity(
                udid: candidate.identity.udid,
                signingRegistrationIdentifier: candidate.identity.signingRegistrationIdentifier,
                usbmuxIdentifier: candidate.identity.usbmuxIdentifier,
                connection: candidate.connection,
                remotePairingIdentifier: candidate.identity.remotePairingIdentifier,
                developerServicesIdentifier: candidate.identity.developerServicesIdentifier,
                connectionGeneration: generation
            )
            let normalized = NativeDeviceDescriptor(identity: identity, connection: candidate.connection)
            if let current = candidatesByUDID[identity.udid]?.first {
                if current.identity.signingRegistrationIdentifier != identity.signingRegistrationIdentifier {
                    throw NativeDeviceBridgeError.invalidIdentity
                }
            }
            candidatesByUDID[identity.udid, default: []].append(normalized)
        }
        alternativesByUDID = candidatesByUDID.mapValues { candidates in
            candidates.sorted { Self.preference($0) < Self.preference($1) }
        }
        return alternativesByUDID.values.compactMap(\.first).sorted { $0.identity.udid < $1.identity.udid }
    }

    private static func preference(_ descriptor: NativeDeviceDescriptor) -> (Int, UInt32) {
        let connectionRank: Int
        switch descriptor.connection {
        case .usb: connectionRank = 0
        case .wireless: connectionRank = 1
        case .unknown: connectionRank = 2
        }
        return (connectionRank, descriptor.identity.usbmuxIdentifier ?? UInt32.max)
    }

    public func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration = .seconds(8)) async throws -> NativeDeviceInspection {
        do {
            return try await transport.inspect(identity, timeout: timeout)
        } catch let original as NativeDeviceBridgeError {
            guard Self.isConnectionLoss(original), identity.connectionGeneration == generation,
                  let alternatives = alternativesByUDID[identity.udid] else {
                throw original
            }
            for candidate in alternatives where
                candidate.identity.usbmuxIdentifier != identity.usbmuxIdentifier
                    || candidate.identity.connection != identity.connection {
                do {
                    return try await transport.inspect(candidate.identity, timeout: timeout)
                } catch let fallback as NativeDeviceBridgeError {
                    guard Self.isConnectionLoss(fallback) else { throw fallback }
                }
            }
            throw original
        }
    }

    private static func isConnectionLoss(_ error: NativeDeviceBridgeError) -> Bool {
        switch error {
        case .deviceNotFound, .deviceDisconnected: true
        default: false
        }
    }
}

/// Dynamic loading keeps Rust declarations in this one file and lets SwiftPM
/// unit tests run without a native library. Release packaging places the dylib
/// in Contents/Frameworks; development may opt in with IOSSIM_DEVICE_BRIDGE_PATH.
public final class DynamicNativeDeviceTransport: NativeDeviceTransport, @unchecked Sendable {
    public static let requiredABIVersion: UInt32 = 2
    private struct CResult {
        let status: Int32
        let payload: UnsafeMutablePointer<UInt8>?
        let payloadLength: Int
        let diagnostic: UnsafeMutablePointer<CChar>?
    }

    private struct WireDevice: Decodable {
        let stableId: String
        let usbmuxId: UInt32
        let connection: DeviceConnectionKind
    }

    private struct WireInspection: Decodable {
        let stableId: String
        let usbmuxId: UInt32
        let connectionGeneration: UInt64
        let connection: DeviceConnectionKind
        let name: String?
        let model: String?
        let osVersion: String?
        let osBuild: String?
        let trust: DeviceTrustState
        let lockState: DeviceLockState
        let developerMode: DeveloperModeReadiness
    }

    private struct WireLockdownPairingReceipt: Decodable {
        let schemaVersion: Int
        let state: String
        let stableId: String
        let usbmuxId: UInt32
        let connectionGeneration: UInt64
        let connection: DeviceConnectionKind
        let pairRecordCreated: Bool
        let pairRecordPersisted: Bool
        let sessionValidated: Bool
    }

    private struct WireApp: Decodable {
        let bundleId: String
        let version: String?
        let teamId: String?
    }

    private struct WireLaunchReceipt: Decodable {
        let bundleId: String
        let pid: UInt32
        let processIdentifierVersion: UInt32
        let appServiceConnected: Bool
    }

    private typealias ABIFn = @convention(c) () -> UInt32
    private typealias ListFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn = @convention(c) (
        UnsafePointer<UInt8>?, Int, UInt32, UInt32, UInt64, UInt64,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> UnsafeMutableRawPointer?
    private typealias InspectFn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
    private typealias PairLockdownOnceFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias CreatePairingFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias ValidatePairingFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias DeveloperSupportStatusFn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
    private typealias MountDeveloperSupportFn = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int,
        UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias InventoryFn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
    private typealias InstallFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, Bool, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias UninstallFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias LaunchFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias DeveloperServicesStatusFn = @convention(c) (
        UnsafeMutableRawPointer?, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias ContainerWriteFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias ContainerReadFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int, UInt64
    ) -> UnsafeMutableRawPointer?
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let listFunction: ListFn?
    private let openFunction: OpenFn?
    private let inspectFunction: InspectFn?
    private let pairLockdownOnceFunction: PairLockdownOnceFn?
    private let createPairingFunction: CreatePairingFn?
    private let validatePairingFunction: ValidatePairingFn?
    private let developerSupportStatusFunction: DeveloperSupportStatusFn?
    private let mountDeveloperSupportFunction: MountDeveloperSupportFn?
    private let inventoryFunction: InventoryFn?
    private let installFunction: InstallFn?
    private let uninstallFunction: UninstallFn?
    private let launchFunction: LaunchFn?
    private let developerServicesStatusFunction: DeveloperServicesStatusFn?
    private let containerWriteFunction: ContainerWriteFn?
    private let containerReadFunction: ContainerReadFn?
    private let closeFunction: CloseFn?
    private let freeFunction: FreeFn?
    public let loadError: NativeDeviceBridgeError?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        let candidates = Self.libraryCandidates(environment: environment, bundle: bundle)
        var loaded: UnsafeMutableRawPointer?
        var loadDiagnostic: String?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            dlerror()
            loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            if loaded != nil { break }
            if let error = dlerror() {
                loadDiagnostic = Self.safeLoadDiagnostic(String(cString: error))
            }
        }
        guard let loaded else {
            handle = nil
            listFunction = nil
            openFunction = nil
            inspectFunction = nil
            pairLockdownOnceFunction = nil
            createPairingFunction = nil
            validatePairingFunction = nil
            developerSupportStatusFunction = nil
            mountDeveloperSupportFunction = nil
            inventoryFunction = nil
            installFunction = nil
            uninstallFunction = nil
            launchFunction = nil
            developerServicesStatusFunction = nil
            containerWriteFunction = nil
            containerReadFunction = nil
            closeFunction = nil
            freeFunction = nil
            loadError = loadDiagnostic.map(NativeDeviceBridgeError.libraryLoadFailure) ?? .libraryUnavailable
            return
        }
        let abi: ABIFn? = Self.symbol("iossim_bridge_abi_version", in: loaded)
        guard abi?() == Self.requiredABIVersion else {
            dlclose(loaded)
            handle = nil
            listFunction = nil
            openFunction = nil
            inspectFunction = nil
            pairLockdownOnceFunction = nil
            createPairingFunction = nil
            validatePairingFunction = nil
            developerSupportStatusFunction = nil
            mountDeveloperSupportFunction = nil
            inventoryFunction = nil
            installFunction = nil
            uninstallFunction = nil
            launchFunction = nil
            developerServicesStatusFunction = nil
            containerWriteFunction = nil
            containerReadFunction = nil
            closeFunction = nil
            freeFunction = nil
            loadError = .incompatibleABI
            return
        }
        handle = loaded
        listFunction = Self.symbol("iossim_bridge_list_devices", in: loaded)
        openFunction = Self.symbol("iossim_bridge_open_device", in: loaded)
        inspectFunction = Self.symbol("iossim_bridge_inspect_device", in: loaded)
        pairLockdownOnceFunction = Self.symbol("iossim_bridge_pair_lockdown_once", in: loaded)
        createPairingFunction = Self.symbol("iossim_bridge_create_remote_pairing", in: loaded)
        validatePairingFunction = Self.symbol("iossim_bridge_validate_remote_pairing", in: loaded)
        developerSupportStatusFunction = Self.symbol("iossim_bridge_developer_support_status", in: loaded)
        mountDeveloperSupportFunction = Self.symbol("iossim_bridge_mount_developer_support", in: loaded)
        inventoryFunction = Self.symbol("iossim_bridge_app_inventory", in: loaded)
        installFunction = Self.symbol("iossim_bridge_install_app", in: loaded)
        uninstallFunction = Self.symbol("iossim_bridge_uninstall_app", in: loaded)
        launchFunction = Self.symbol("iossim_bridge_launch_app", in: loaded)
        developerServicesStatusFunction = Self.symbol("iossim_bridge_developer_services_status", in: loaded)
        containerWriteFunction = Self.symbol("iossim_bridge_container_write", in: loaded)
        containerReadFunction = Self.symbol("iossim_bridge_container_read", in: loaded)
        closeFunction = Self.symbol("iossim_bridge_close_device", in: loaded)
        freeFunction = Self.symbol("iossim_bridge_result_free", in: loaded)
        loadError = [
            listFunction != nil, openFunction != nil, inspectFunction != nil,
            pairLockdownOnceFunction != nil,
            createPairingFunction != nil, validatePairingFunction != nil,
            developerSupportStatusFunction != nil, mountDeveloperSupportFunction != nil,
            inventoryFunction != nil, installFunction != nil, uninstallFunction != nil,
            containerWriteFunction != nil, containerReadFunction != nil,
            closeFunction != nil, freeFunction != nil
        ]
            .allSatisfy { $0 } ? nil : .incompatibleABI
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    public func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor] {
        if let loadError { throw loadError }
        guard let listFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        let data = try consume(listFunction(Self.milliseconds(timeout)))
        do {
            return try Self.decodeDeviceListPayload(data)
        } catch let error as NativeDeviceBridgeError {
            throw error
        } catch {
            throw NativeDeviceBridgeError.decodingFailure("device list payload did not match bridge ABI")
        }
    }

    public func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection {
        if let loadError { throw loadError }
        guard let openFunction, let inspectFunction, let closeFunction else {
            throw NativeDeviceBridgeError.incompatibleABI
        }
        var deviceHandle: UnsafeMutableRawPointer?
        let timeoutMS = Self.milliseconds(timeout)
        let bytes = Array(identity.udid.utf8)
        let openResult = bytes.withUnsafeBufferPointer { buffer in
            openFunction(
                buffer.baseAddress, buffer.count,
                identity.usbmuxIdentifier ?? 0,
                Self.connectionCode(identity.connection),
                identity.connectionGeneration, timeoutMS, &deviceHandle
            )
        }
        _ = try consume(openResult)
        guard let deviceHandle else { throw NativeDeviceBridgeError.internalFailure("native bridge did not return a handle") }
        defer { closeFunction(deviceHandle) }
        let data = try consume(inspectFunction(deviceHandle, timeoutMS))
        let value: WireInspection
        do {
            value = try JSONDecoder().decode(WireInspection.self, from: data)
        } catch {
            throw NativeDeviceBridgeError.decodingFailure("device inspection payload did not match bridge ABI")
        }
        let returnedIdentity = try IOSSimDeviceIdentity(
            udid: value.stableId,
            usbmuxIdentifier: value.usbmuxId,
            connection: value.connection,
            connectionGeneration: value.connectionGeneration
        )
        guard identity.binds(to: returnedIdentity), identity.connectionGeneration == returnedIdentity.connectionGeneration else {
            throw NativeDeviceBridgeError.deviceDisconnected
        }
        return NativeDeviceInspection(
            identity: returnedIdentity,
            connection: value.connection,
            name: value.name,
            model: value.model,
            osVersion: value.osVersion,
            osBuild: value.osBuild,
            trust: value.trust,
            lockState: value.lockState,
            developerMode: value.developerMode
        )
    }

    public func pairLockdownOnce(
        on identity: IOSSimDeviceIdentity,
        hostName: String = "IOSSim",
        timeout: Duration = .seconds(20)
    ) throws -> LockdownPairingReceipt {
        guard !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hostName.utf8.count <= 256,
              identity.usbmuxIdentifier != nil,
              identity.connection == .usb,
              let pairLockdownOnceFunction else {
            throw NativeDeviceBridgeError.invalidIdentity
        }
        let data = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let bytes = Array(hostName.utf8)
            let pointer = bytes.withUnsafeBufferPointer {
                pairLockdownOnceFunction(handle, $0.baseAddress, $0.count, timeoutMS)
            }
            return try consume(pointer)
        }
        let wire: WireLockdownPairingReceipt
        do {
            wire = try JSONDecoder().decode(WireLockdownPairingReceipt.self, from: data)
        } catch {
            throw NativeDeviceBridgeError.decodingFailure("Lockdown pairing receipt did not match bridge ABI")
        }
        guard wire.schemaVersion == LockdownPairingReceipt.currentSchemaVersion,
              wire.state == LockdownPairingState.lockdownSessionValidated.rawValue,
              wire.stableId == identity.udid,
              wire.usbmuxId == identity.usbmuxIdentifier,
              wire.connectionGeneration == identity.connectionGeneration,
              wire.connection == identity.connection,
              wire.pairRecordPersisted,
              wire.sessionValidated else {
            throw NativeDeviceBridgeError.protocolFailure("Lockdown pairing receipt identity or validation mismatch")
        }
        let returnedIdentity = try IOSSimDeviceIdentity(
            udid: wire.stableId,
            usbmuxIdentifier: wire.usbmuxId,
            connection: wire.connection,
            connectionGeneration: wire.connectionGeneration
        )
        return LockdownPairingReceipt(
            schemaVersion: wire.schemaVersion,
            state: .lockdownSessionValidated,
            identity: returnedIdentity,
            pairRecordCreated: wire.pairRecordCreated,
            pairRecordPersisted: wire.pairRecordPersisted,
            sessionValidated: wire.sessionValidated
        )
    }

    public func createRemotePairing(
        on identity: IOSSimDeviceIdentity,
        hostname: String,
        timeout: Duration = .seconds(120)
    ) throws -> Data {
        guard !hostname.isEmpty, hostname.utf8.count <= 256, let createPairingFunction else {
            throw NativeDeviceBridgeError.incompatibleABI
        }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let host = Array(hostname.utf8)
            let pointer = host.withUnsafeBufferPointer {
                createPairingFunction(handle, $0.baseAddress, $0.count, timeoutMS)
            }
            return try consume(pointer)
        }
    }

    public func validateRemotePairing(
        on identity: IOSSimDeviceIdentity,
        hostname: String,
        pairingData: Data,
        timeout: Duration = .seconds(60)
    ) throws {
        guard !hostname.isEmpty, hostname.utf8.count <= 256, !pairingData.isEmpty,
              pairingData.count <= 16 * 1_024 * 1_024, let validatePairingFunction else {
            throw NativeDeviceBridgeError.incompatibleABI
        }
        _ = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let host = Array(hostname.utf8)
            let pointer = host.withUnsafeBufferPointer { hostBuffer in
                pairingData.withUnsafeBytes { dataBuffer in
                    validatePairingFunction(
                        handle, hostBuffer.baseAddress, hostBuffer.count,
                        dataBuffer.bindMemory(to: UInt8.self).baseAddress, dataBuffer.count,
                        timeoutMS
                    )
                }
            }
            return try consume(pointer)
        }
    }

    public func developerSupportMounted(
        on identity: IOSSimDeviceIdentity,
        timeout: Duration = .seconds(20)
    ) throws -> Bool {
        guard let developerSupportStatusFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            struct Status: Decodable { let mounted: Bool }
            let data = try consume(developerSupportStatusFunction(handle, timeoutMS))
            return try JSONDecoder().decode(Status.self, from: data).mounted
        }
    }

    public func mountDeveloperSupport(
        on identity: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        timeout: Duration = .seconds(120)
    ) throws {
        guard let trustCache = artifact.trustCacheURL else {
            throw DeveloperSupportFailure.corruptAsset
        }
        guard let mountDeveloperSupportFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        _ = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let image = Array(artifact.imageURL.path.utf8)
            let trust = Array(trustCache.path.utf8)
            let manifest = Array(artifact.buildManifestURL.path.utf8)
            let pointer = image.withUnsafeBufferPointer { imageBuffer in
                trust.withUnsafeBufferPointer { trustBuffer in
                    manifest.withUnsafeBufferPointer { manifestBuffer in
                        mountDeveloperSupportFunction(
                            handle,
                            imageBuffer.baseAddress, imageBuffer.count,
                            trustBuffer.baseAddress, trustBuffer.count,
                            manifestBuffer.baseAddress, manifestBuffer.count,
                            timeoutMS
                        )
                    }
                }
            }
            return try consume(pointer)
        }
    }

    public func applicationInventory(
        on identity: IOSSimDeviceIdentity,
        timeout: Duration = .seconds(20)
    ) throws -> [NativeInstalledApplication] {
        guard let inventoryFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let data = try consume(inventoryFunction(handle, timeoutMS))
            return try JSONDecoder().decode([WireApp].self, from: data).map {
                NativeInstalledApplication(bundleIdentifier: $0.bundleId, version: $0.version, teamIdentifier: $0.teamId)
            }
        }
    }

    public func installApplication(
        on identity: IOSSimDeviceIdentity,
        localURL: URL,
        upgrade: Bool,
        timeout: Duration = .seconds(120)
    ) throws {
        guard localURL.isFileURL, localURL.path.hasPrefix("/"), let installFunction else {
            throw NativeDeviceBridgeError.invalidIdentity
        }
        _ = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let path = Array(localURL.path.utf8)
            let pointer = path.withUnsafeBufferPointer {
                installFunction(handle, $0.baseAddress, $0.count, upgrade, timeoutMS)
            }
            return try consume(pointer)
        }
    }

    public func uninstallApplication(
        on identity: IOSSimDeviceIdentity,
        bundleIdentifier: String,
        timeout: Duration = .seconds(60)
    ) throws {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(bundleIdentifier), let uninstallFunction else {
            throw NativeDeviceBridgeError.invalidIdentity
        }
        _ = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let bundle = Array(bundleIdentifier.utf8)
            let pointer = bundle.withUnsafeBufferPointer {
                uninstallFunction(handle, $0.baseAddress, $0.count, timeoutMS)
            }
            return try consume(pointer)
        }
    }

    public func launchApplication(
        on identity: IOSSimDeviceIdentity,
        bundleIdentifier: String,
        timeout: Duration = .seconds(60)
    ) throws -> NativeLaunchReceipt {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(bundleIdentifier) else {
            throw NativeDeviceBridgeError.invalidIdentity
        }
        guard let launchFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let bundle = Array(bundleIdentifier.utf8)
            let pointer = bundle.withUnsafeBufferPointer {
                launchFunction(handle, $0.baseAddress, $0.count, timeoutMS)
            }
            let data = try consume(pointer)
            let receipt = try JSONDecoder().decode(WireLaunchReceipt.self, from: data)
            return NativeLaunchReceipt(
                bundleIdentifier: receipt.bundleId,
                pid: receipt.pid,
                processIdentifierVersion: receipt.processIdentifierVersion,
                appServiceConnected: receipt.appServiceConnected
            )
        }
    }

    public func developerServicesReadiness(
        on identity: IOSSimDeviceIdentity,
        timeout: Duration = .seconds(60)
    ) throws -> DeveloperServicesReadinessReceipt {
        guard let developerServicesStatusFunction else {
            throw NativeDeviceBridgeError.incompatibleABI
        }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let data = try consume(developerServicesStatusFunction(handle, timeoutMS))
            return try JSONDecoder().decode(DeveloperServicesReadinessReceipt.self, from: data)
        }
    }

    public func writeContainer(
        on identity: IOSSimDeviceIdentity,
        bundleIdentifier: String,
        relativePath: String,
        data: Data,
        timeout: Duration = .seconds(30)
    ) throws {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(bundleIdentifier),
              NativeApplicationPathPolicy.isSafeContainerPath(relativePath), data.count <= 16 * 1_024 * 1_024,
              let containerWriteFunction else { throw NativeApplicationManagementError.unsafePath }
        _ = try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let bundle = Array(bundleIdentifier.utf8)
            let path = Array(relativePath.utf8)
            let pointer = bundle.withUnsafeBufferPointer { bundleBuffer in
                path.withUnsafeBufferPointer { pathBuffer in
                    data.withUnsafeBytes { dataBuffer in
                        containerWriteFunction(
                            handle, bundleBuffer.baseAddress, bundleBuffer.count,
                            pathBuffer.baseAddress, pathBuffer.count,
                            dataBuffer.bindMemory(to: UInt8.self).baseAddress, dataBuffer.count, timeoutMS
                        )
                    }
                }
            }
            return try consume(pointer)
        }
    }

    public func readContainer(
        on identity: IOSSimDeviceIdentity,
        bundleIdentifier: String,
        relativePath: String,
        timeout: Duration = .seconds(30)
    ) throws -> Data {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(bundleIdentifier),
              NativeApplicationPathPolicy.isSafeContainerPath(relativePath), let containerReadFunction else {
            throw NativeApplicationManagementError.unsafePath
        }
        return try withHandle(identity, timeout: timeout) { handle, timeoutMS in
            let bundle = Array(bundleIdentifier.utf8)
            let path = Array(relativePath.utf8)
            let pointer = bundle.withUnsafeBufferPointer { bundleBuffer in
                path.withUnsafeBufferPointer { pathBuffer in
                    containerReadFunction(
                        handle, bundleBuffer.baseAddress, bundleBuffer.count,
                        pathBuffer.baseAddress, pathBuffer.count, timeoutMS
                    )
                }
            }
            return try consume(pointer)
        }
    }

    public static func libraryCandidates(
        environment: [String: String],
        bundle: Bundle,
        executableURL: URL? = Bundle.main.executableURL
    ) -> [String] {
        var candidates: [String] = []
        if let explicit = environment["IOSSIM_DEVICE_BRIDGE_PATH"], explicit.hasPrefix("/") {
            candidates.append(explicit)
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Frameworks/libiossim_device_bridge.dylib").path)
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("NativeDeviceBridge/libiossim_device_bridge.dylib").path)
        }
        if let executableURL {
            let macOSDirectory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            if macOSDirectory.lastPathComponent == "MacOS", contentsDirectory.lastPathComponent == "Contents" {
                candidates.append(contentsDirectory
                    .appendingPathComponent("Resources/NativeDeviceBridge/libiossim_device_bridge.dylib")
                    .path)
            }
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    static func decodeDeviceListPayload(_ data: Data) throws -> [NativeDeviceDescriptor] {
        try JSONDecoder().decode([WireDevice].self, from: data).map { value in
            NativeDeviceDescriptor(
                identity: try IOSSimDeviceIdentity(
                    udid: value.stableId,
                    usbmuxIdentifier: value.usbmuxId,
                    connection: value.connection
                ),
                connection: value.connection
            )
        }
    }

    static func safeLoadDiagnostic(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("different team ids") || lowered.contains("library validation") || lowered.contains("code signature") {
            return "native bridge rejected by hardened runtime library validation"
        }
        if lowered.contains("wrong architecture") || lowered.contains("no suitable image") || lowered.contains("incompatible architecture") {
            return "native bridge architecture is incompatible with this process"
        }
        if lowered.contains("image not found") || lowered.contains("no such file") {
            return "a native bridge dependency is missing"
        }
        return "native bridge could not be loaded"
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        guard seconds >= 0 else { return 1 }
        let value = UInt64(seconds) * 1_000 + UInt64(max(0, attoseconds) / 1_000_000_000_000_000)
        return min(max(value, 1), 120_000)
    }

    private func consume(_ pointer: UnsafeMutableRawPointer?) throws -> Data {
        guard let pointer, let freeFunction else { throw NativeDeviceBridgeError.internalFailure("native bridge returned no result") }
        defer { freeFunction(pointer) }
        let result = pointer.assumingMemoryBound(to: CResult.self).pointee
        let diagnostic = result.diagnostic.map { String(cString: $0) } ?? "device operation failed"
        guard result.status == 0 else { throw Self.error(status: result.status, diagnostic: diagnostic) }
        guard result.payloadLength == 0 || result.payload != nil else {
            throw NativeDeviceBridgeError.internalFailure("native bridge returned an invalid buffer")
        }
        return result.payload.map { Data(bytes: $0, count: result.payloadLength) } ?? Data()
    }

    private func withHandle<T>(
        _ identity: IOSSimDeviceIdentity,
        timeout: Duration,
        operation: (UnsafeMutableRawPointer, UInt64) throws -> T
    ) throws -> T {
        if let loadError { throw loadError }
        guard let openFunction, let closeFunction else { throw NativeDeviceBridgeError.incompatibleABI }
        let timeoutMS = Self.milliseconds(timeout)
        let bytes = Array(identity.udid.utf8)
        var deviceHandle: UnsafeMutableRawPointer?
        let result = bytes.withUnsafeBufferPointer { buffer in
            openFunction(
                buffer.baseAddress, buffer.count,
                identity.usbmuxIdentifier ?? 0,
                Self.connectionCode(identity.connection),
                identity.connectionGeneration, timeoutMS, &deviceHandle
            )
        }
        _ = try consume(result)
        guard let deviceHandle else { throw NativeDeviceBridgeError.internalFailure("native bridge did not return a handle") }
        defer { closeFunction(deviceHandle) }
        return try operation(deviceHandle, timeoutMS)
    }

    private static func error(status: Int32, diagnostic: String) -> NativeDeviceBridgeError {
        switch status {
        case 1: return .invalidIdentity
        case 2: return .libraryUnavailable
        case 3: return .deviceNotFound
        case 4: return .deviceDisconnected
        case 5: return .deviceLocked
        case 6: return .trustRequired
        case 7: return .developerModeRequired
        case 8: return .cancelled
        case 9: return .timedOut
        case 10: return .protocolFailure(Redactor.redact(diagnostic))
        case 12: return .deviceResolutionFailed(Redactor.redact(diagnostic))
        case 13: return .coreDeviceProxyFailed(Redactor.redact(diagnostic))
        case 14: return .softwareTunnelFailed(Redactor.redact(diagnostic))
        case 15: return .rsdUnavailable(Redactor.redact(diagnostic))
        case 16: return .remoteXPCFailed(Redactor.redact(diagnostic))
        case 17: return .appServiceUnavailable(Redactor.redact(diagnostic))
        case 18: return .featureUnavailable(Redactor.redact(diagnostic))
        case 19: return .applicationNotFound(Redactor.redact(diagnostic))
        case 20: return .ddiRequired(Redactor.redact(diagnostic))
        case 21: return .developerServicesNotReady(Redactor.redact(diagnostic))
        case 22: return .launchRejected(Redactor.redact(diagnostic))
        case 23: return .containerUnavailable(Redactor.redact(diagnostic))
        case 24: return .pairingRejected(Redactor.redact(diagnostic))
        case 25: return .trustPromptPending
        case 26: return .trustDenied
        default: return .internalFailure(Redactor.redact(diagnostic))
        }
    }

    private static func connectionCode(_ connection: DeviceConnectionKind?) -> UInt32 {
        switch connection {
        case .usb: return 1
        case .wireless: return 2
        case .unknown, nil: return 0
        }
    }
}
