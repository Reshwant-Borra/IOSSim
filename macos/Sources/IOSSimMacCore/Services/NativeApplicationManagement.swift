import CryptoKit
import Foundation

public struct NativeInstalledApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String?
    public let teamIdentifier: String?

    public init(bundleIdentifier: String, version: String? = nil, teamIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.teamIdentifier = teamIdentifier
    }
}

public struct NativeLaunchReceipt: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let pid: UInt32
    public let processIdentifierVersion: UInt32
    public let appServiceConnected: Bool

    public init(
        bundleIdentifier: String,
        pid: UInt32,
        processIdentifierVersion: UInt32,
        appServiceConnected: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.processIdentifierVersion = processIdentifierVersion
        self.appServiceConnected = appServiceConnected
    }
}

public enum NativeApplicationInstallMode: String, Codable, Equatable, Sendable {
    case fresh
    case upgrade
}

public struct NativeApplicationInstallReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operationIdentifier: UUID
    public let deviceUDIDHash: String
    public let usbmuxIdentifier: UInt32?
    public let connection: DeviceConnectionKind?
    public let connectionGeneration: UInt64
    public let mode: NativeApplicationInstallMode
    public let bundleIdentifier: String
    public let version: String
    public let teamIdentifier: String
    public let artifactSHA256: String
    public let reconciledAfterInterruptedResponse: Bool
    public let completedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        operationIdentifier: UUID = UUID(),
        deviceUDIDHash: String,
        usbmuxIdentifier: UInt32?,
        connection: DeviceConnectionKind?,
        connectionGeneration: UInt64,
        mode: NativeApplicationInstallMode,
        bundleIdentifier: String,
        version: String,
        teamIdentifier: String,
        artifactSHA256: String,
        reconciledAfterInterruptedResponse: Bool,
        completedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.operationIdentifier = operationIdentifier
        self.deviceUDIDHash = deviceUDIDHash
        self.usbmuxIdentifier = usbmuxIdentifier
        self.connection = connection
        self.connectionGeneration = connectionGeneration
        self.mode = mode
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.teamIdentifier = teamIdentifier
        self.artifactSHA256 = artifactSHA256
        self.reconciledAfterInterruptedResponse = reconciledAfterInterruptedResponse
        self.completedAt = completedAt
    }
}

public enum RuntimeConfigurationReconciliationResult: String, Codable, Equatable, Sendable {
    case alreadyCurrent = "ALREADY_CURRENT"
    case writtenAndVerified = "WRITTEN_AND_VERIFIED"
}

public struct RuntimeMappingPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let deviceUDIDHash: String
    public let teamIdentifier: String?
    public let mainBundleIdentifier: String
    public let runnerBundleIdentifier: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        deviceUDIDHash: String,
        teamIdentifier: String? = nil,
        mainBundleIdentifier: String,
        runnerBundleIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.deviceUDIDHash = deviceUDIDHash
        self.teamIdentifier = teamIdentifier
        self.mainBundleIdentifier = mainBundleIdentifier
        self.runnerBundleIdentifier = runnerBundleIdentifier
    }

    public var semanticallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !deviceUDIDHash.isEmpty
            && NativeApplicationPathPolicy.isValidBundleIdentifier(mainBundleIdentifier)
            && NativeApplicationPathPolicy.isValidBundleIdentifier(runnerBundleIdentifier)
    }
}

public enum NativeApplicationManagementError: String, Error, Codable, Equatable, Sendable {
    case invalidSignedApplication
    case wrongBundleIdentifier
    case inventoryMismatch
    case applicationMissing
    case runnerMissing
    case launchFailed
    case unsafePath
    case readbackMismatch
    case selectedDeviceMismatch
    case profileTrustRequired
    case expiredSignature
    case deviceLocked
    case developerModeRequired
    case serviceUnavailable
    case ownershipConflict
}

public enum NativeApplicationPathPolicy {
    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        (3...255).contains(value.utf8.count)
            && value.contains(".")
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
            }
    }

    public static func isSafeContainerPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("/")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

public protocol NativeApplicationServicing: Sendable {
    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication]
    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws
    func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws
    func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data
}

public protocol NativeRSDApplicationLaunching: Sendable {
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws -> NativeLaunchReceipt
}

public struct AwaitingPhysicalAppServiceLauncher: NativeRSDApplicationLaunching {
    public init() {}
    public func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws -> NativeLaunchReceipt {
        throw NativeApplicationManagementError.serviceUnavailable
    }
}

public struct NativeAppServiceLauncher: NativeRSDApplicationLaunching {
    private let transport: DynamicNativeDeviceTransport

    public init(transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport()) {
        self.transport = transport
    }

    public func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws -> NativeLaunchReceipt {
        try transport.launchApplication(on: device, bundleIdentifier: bundleIdentifier)
    }
}

public struct NativeApplicationService: NativeApplicationServicing {
    private let transport: DynamicNativeDeviceTransport
    private let launcher: any NativeRSDApplicationLaunching

    public init(
        transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport(),
        launcher: (any NativeRSDApplicationLaunching)? = nil
    ) {
        self.transport = transport
        self.launcher = launcher ?? NativeAppServiceLauncher(transport: transport)
    }

    public func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] {
        try transport.applicationInventory(on: device)
    }

    public func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {
        try transport.installApplication(on: device, localURL: appURL, upgrade: mode == .upgrade)
    }

    public func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        try transport.uninstallApplication(on: device, bundleIdentifier: bundleIdentifier)
    }

    public func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        _ = try await launcher.launch(bundleIdentifier: bundleIdentifier, on: device)
    }

    public func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws {
        try transport.writeContainer(on: device, bundleIdentifier: bundleIdentifier, relativePath: relativePath, data: data)
    }

    public func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        try transport.readContainer(on: device, bundleIdentifier: bundleIdentifier, relativePath: relativePath)
    }
}

public actor NativeApplicationManager {
    public static let runtimeMappingPath = "Library/Application Support/IOSSim/runtime-mapping.json"
    private let service: any NativeApplicationServicing

    public init(service: any NativeApplicationServicing = NativeApplicationService()) {
        self.service = service
    }

    public func installOrUpgrade(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        on device: IOSSimDeviceIdentity
    ) async throws -> NativeApplicationInstallMode {
        try await installOrUpgradeReceipt(
            appURL: appURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            on: device
        ).mode
    }

    public func installOrUpgradeReceipt(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        on device: IOSSimDeviceIdentity
    ) async throws -> NativeApplicationInstallReceipt {
        try Self.validateSignedApp(
            at: appURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
        let expectedVersion = try Self.applicationVersion(at: appURL)
        let artifactSHA256 = try Self.applicationTreeSHA256(at: appURL)
        let before = try await service.inventory(on: device)
        let existing = before.first { $0.bundleIdentifier == expectedBundleIdentifier }
        if let existing, existing.teamIdentifier != expectedTeamIdentifier {
            throw NativeApplicationManagementError.ownershipConflict
        }
        let mode: NativeApplicationInstallMode = existing == nil ? .fresh : .upgrade
        var reconciledAfterInterruptedResponse = false
        do {
            try await service.install(appURL: appURL, mode: mode, on: device)
        } catch {
            // Inventory reports bundle/version/team, not the signature. If a matching app was already
            // installed (a re-sign of the same version), a lost response is indistinguishable from failure.
            if existing?.version == expectedVersion { throw error }
            let reconciled = try? await service.inventory(on: device).first {
                $0.bundleIdentifier == expectedBundleIdentifier
                    && $0.teamIdentifier == expectedTeamIdentifier
                    && $0.version == expectedVersion
            }
            guard reconciled != nil else { throw error }
            reconciledAfterInterruptedResponse = true
        }
        let after = try await service.inventory(on: device)
        guard let installed = after.first(where: { $0.bundleIdentifier == expectedBundleIdentifier }),
              installed.teamIdentifier == expectedTeamIdentifier,
              installed.version == expectedVersion else {
            throw NativeApplicationManagementError.inventoryMismatch
        }
        return NativeApplicationInstallReceipt(
            deviceUDIDHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(device.udid),
            usbmuxIdentifier: device.usbmuxIdentifier,
            connection: device.connection,
            connectionGeneration: device.connectionGeneration,
            mode: mode,
            bundleIdentifier: expectedBundleIdentifier,
            version: expectedVersion,
            teamIdentifier: expectedTeamIdentifier,
            artifactSHA256: artifactSHA256,
            reconciledAfterInterruptedResponse: reconciledAfterInterruptedResponse
        )
    }

    public func verifyInstallation(
        mainBundleIdentifier: String,
        runnerBundleIdentifier: String,
        expectedTeamIdentifier: String,
        on device: IOSSimDeviceIdentity
    ) async throws -> [NativeInstalledApplication] {
        let inventory = try await service.inventory(on: device)
        guard let main = inventory.first(where: { $0.bundleIdentifier == mainBundleIdentifier }) else {
            throw NativeApplicationManagementError.applicationMissing
        }
        guard let runner = inventory.first(where: { $0.bundleIdentifier == runnerBundleIdentifier }) else {
            throw NativeApplicationManagementError.runnerMissing
        }
        guard [main, runner].allSatisfy({ $0.teamIdentifier == expectedTeamIdentifier }) else {
            throw NativeApplicationManagementError.inventoryMismatch
        }
        return [main, runner]
    }

    public func uninstallIOSSimOwned(
        bundleIdentifiers: Set<String>,
        allowedBundleIdentifiers: Set<String>,
        expectedTeamIdentifier: String,
        on device: IOSSimDeviceIdentity
    ) async throws {
        guard bundleIdentifiers.isSubset(of: allowedBundleIdentifiers), !expectedTeamIdentifier.isEmpty else {
            throw NativeApplicationManagementError.wrongBundleIdentifier
        }
        let before = try await service.inventory(on: device)
        for identifier in bundleIdentifiers.sorted() {
            guard let installed = before.first(where: { $0.bundleIdentifier == identifier }) else { continue }
            guard installed.teamIdentifier == expectedTeamIdentifier else {
                throw NativeApplicationManagementError.ownershipConflict
            }
            try await service.uninstall(bundleIdentifier: identifier, on: device)
        }
        let after = try await service.inventory(on: device)
        guard !after.contains(where: { bundleIdentifiers.contains($0.bundleIdentifier) }) else {
            throw NativeApplicationManagementError.inventoryMismatch
        }
    }

    public func launchMain(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(bundleIdentifier) else {
            throw NativeApplicationManagementError.wrongBundleIdentifier
        }
        try await service.launch(bundleIdentifier: bundleIdentifier, on: device)
    }

    public func writeAndVerifyRuntimeMapping(
        mainBundleIdentifier: String,
        runnerBundleIdentifier: String,
        teamIdentifier: String? = nil,
        on device: IOSSimDeviceIdentity
    ) async throws -> RuntimeConfigurationReconciliationResult {
        let mapping = Self.expectedRuntimeMapping(
            mainBundleIdentifier: mainBundleIdentifier,
            runnerBundleIdentifier: runnerBundleIdentifier,
            teamIdentifier: teamIdentifier,
            device: device
        )
        guard mapping.semanticallyValid else {
            throw NativeApplicationManagementError.readbackMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mapping)
        if (try? await verifyRuntimeMapping(
            mainBundleIdentifier: mainBundleIdentifier,
            runnerBundleIdentifier: runnerBundleIdentifier,
            teamIdentifier: teamIdentifier,
            on: device
        )) == true {
            return .alreadyCurrent
        }
        try await service.writeContainer(
            bundleIdentifier: mainBundleIdentifier,
            relativePath: Self.runtimeMappingPath,
            data: data,
            on: device
        )
        let receipt = try await service.readContainer(
            bundleIdentifier: mainBundleIdentifier,
            relativePath: Self.runtimeMappingPath,
            on: device
        )
        guard let decoded = try? JSONDecoder().decode(RuntimeMappingPayload.self, from: receipt),
              decoded == mapping, decoded.semanticallyValid else {
            throw NativeApplicationManagementError.readbackMismatch
        }
        return .writtenAndVerified
    }

    public func verifyRuntimeMapping(
        mainBundleIdentifier: String,
        runnerBundleIdentifier: String,
        teamIdentifier: String? = nil,
        on device: IOSSimDeviceIdentity
    ) async throws -> Bool {
        let expected = Self.expectedRuntimeMapping(
            mainBundleIdentifier: mainBundleIdentifier,
            runnerBundleIdentifier: runnerBundleIdentifier,
            teamIdentifier: teamIdentifier,
            device: device
        )
        let data = try await service.readContainer(
            bundleIdentifier: mainBundleIdentifier,
            relativePath: Self.runtimeMappingPath,
            on: device
        )
        guard let decoded = try? JSONDecoder().decode(RuntimeMappingPayload.self, from: data) else {
            return false
        }
        return decoded == expected && decoded.semanticallyValid
    }

    private static func expectedRuntimeMapping(
        mainBundleIdentifier: String,
        runnerBundleIdentifier: String,
        teamIdentifier: String?,
        device: IOSSimDeviceIdentity
    ) -> RuntimeMappingPayload {
        RuntimeMappingPayload(
            deviceUDIDHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(device.udid),
            teamIdentifier: teamIdentifier,
            mainBundleIdentifier: mainBundleIdentifier,
            runnerBundleIdentifier: runnerBundleIdentifier
        )
    }

    public static func validateSignedApp(
        at appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws {
        guard appURL.isFileURL,
              appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.appendingPathComponent("embedded.mobileprovision").path),
              FileManager.default.fileExists(atPath: appURL.appendingPathComponent("_CodeSignature/CodeResources").path),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              NativeApplicationPathPolicy.isValidBundleIdentifier(expectedBundleIdentifier),
              !expectedTeamIdentifier.isEmpty else {
            throw NativeApplicationManagementError.invalidSignedApplication
        }
    }

    private static func applicationVersion(at appURL: URL) throws -> String {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let version = (info["CFBundleShortVersionString"] as? String)
                ?? (info["CFBundleVersion"] as? String),
              !version.isEmpty else {
            throw NativeApplicationManagementError.invalidSignedApplication
        }
        return version
    }

    private static func applicationTreeSHA256(at appURL: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw NativeApplicationManagementError.invalidSignedApplication
        }
        let entries = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for entry in entries {
            let relative = String(entry.path.dropFirst(appURL.path.count + 1))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                hasher.update(data: Data("symlink".utf8))
                hasher.update(data: Data((try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)).utf8))
            } else if values.isRegularFile == true {
                hasher.update(data: Data("file".utf8))
                let handle = try FileHandle(forReadingFrom: entry)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            } else {
                hasher.update(data: Data("directory".utf8))
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct NativeApplicationInventoryReader: DeviceApplicationInventoryReading {
    private let service: any NativeApplicationServicing
    private let deviceBackend: (any DeviceProvisioningBackend)?

    public init(
        service: any NativeApplicationServicing = NativeApplicationService(),
        deviceBackend: (any DeviceProvisioningBackend)? = nil
    ) {
        self.service = service
        self.deviceBackend = deviceBackend
    }

    public func read(rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> DeviceApplicationInventory {
        let identity: IOSSimDeviceIdentity?
        if let deviceBackend {
            identity = await deviceBackend.nativeDeviceIdentity(
                matching: rawDeviceIdentifier,
                context: context
            )
        } else {
            identity = try? IOSSimDeviceIdentity(udid: rawDeviceIdentifier)
        }
        guard let identity else {
            return DeviceApplicationInventory(
                selectedDeviceMatches: false, bundleIdentifiers: [], failureCode: .deviceUnavailable,
                safeReason: "selected device identity is invalid"
            )
        }
        do {
            let apps = try await service.inventory(on: identity)
            return DeviceApplicationInventory(
                selectedDeviceMatches: true,
                bundleIdentifiers: Set(apps.map(\.bundleIdentifier))
            )
        } catch {
            return DeviceApplicationInventory(
                selectedDeviceMatches: false, bundleIdentifiers: [], failureCode: .deviceUnavailable,
                safeReason: "native application inventory unavailable"
            )
        }
    }
}
