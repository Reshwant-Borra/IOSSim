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

public enum NativeApplicationInstallMode: String, Codable, Equatable, Sendable {
    case fresh
    case upgrade
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
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws
}

public struct AwaitingPhysicalAppServiceLauncher: NativeRSDApplicationLaunching {
    public init() {}
    public func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        throw NativeApplicationManagementError.serviceUnavailable
    }
}

public struct NativeApplicationService: NativeApplicationServicing {
    private let transport: DynamicNativeDeviceTransport
    private let launcher: any NativeRSDApplicationLaunching

    public init(
        transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport(),
        launcher: any NativeRSDApplicationLaunching = AwaitingPhysicalAppServiceLauncher()
    ) {
        self.transport = transport
        self.launcher = launcher
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
        try await launcher.launch(bundleIdentifier: bundleIdentifier, on: device)
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
        try Self.validateSignedApp(
            at: appURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
        let before = try await service.inventory(on: device)
        let mode: NativeApplicationInstallMode = before.contains { $0.bundleIdentifier == expectedBundleIdentifier }
            ? .upgrade : .fresh
        try await service.install(appURL: appURL, mode: mode, on: device)
        let after = try await service.inventory(on: device)
        guard let installed = after.first(where: { $0.bundleIdentifier == expectedBundleIdentifier }) else {
            throw NativeApplicationManagementError.inventoryMismatch
        }
        if let team = installed.teamIdentifier, team != expectedTeamIdentifier {
            throw NativeApplicationManagementError.inventoryMismatch
        }
        return mode
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
        guard [main, runner].allSatisfy({ $0.teamIdentifier == nil || $0.teamIdentifier == expectedTeamIdentifier }) else {
            throw NativeApplicationManagementError.inventoryMismatch
        }
        return [main, runner]
    }

    public func uninstallIOSSimOwned(
        bundleIdentifiers: Set<String>,
        allowedBundleIdentifiers: Set<String>,
        on device: IOSSimDeviceIdentity
    ) async throws {
        guard bundleIdentifiers.isSubset(of: allowedBundleIdentifiers) else {
            throw NativeApplicationManagementError.wrongBundleIdentifier
        }
        for identifier in bundleIdentifiers.sorted() {
            try await service.uninstall(bundleIdentifier: identifier, on: device)
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
        on device: IOSSimDeviceIdentity
    ) async throws {
        let mapping = RuntimeMappingPayload(
            schemaVersion: 1,
            deviceUDIDHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(device.udid),
            mainBundleIdentifier: mainBundleIdentifier,
            runnerBundleIdentifier: runnerBundleIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mapping)
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
        guard receipt == data else { throw NativeApplicationManagementError.readbackMismatch }
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
}

private struct RuntimeMappingPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let deviceUDIDHash: String
    let mainBundleIdentifier: String
    let runnerBundleIdentifier: String
}

public struct NativeApplicationInventoryReader: DeviceApplicationInventoryReading {
    private let service: any NativeApplicationServicing

    public init(service: any NativeApplicationServicing = NativeApplicationService()) {
        self.service = service
    }

    public func read(rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> DeviceApplicationInventory {
        guard let identity = try? IOSSimDeviceIdentity(udid: rawDeviceIdentifier) else {
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
