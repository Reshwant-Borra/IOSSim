import Foundation

public struct InstallationInventoryRetryPolicy: Equatable, Sendable {
    /// Delays before attempts after the initial authoritative refresh. The
    /// production window is bounded at 6.2 seconds over seven total reads.
    public static let postInstall = InstallationInventoryRetryPolicy(
        backoffNanoseconds: [200_000_000, 400_000_000, 800_000_000, 1_200_000_000, 1_600_000_000, 2_000_000_000]
    )
    public static let immediateTesting = InstallationInventoryRetryPolicy(
        backoffNanoseconds: [0, 0, 0, 0, 0, 0]
    )

    public let backoffNanoseconds: [UInt64]

    public init(backoffNanoseconds: [UInt64]) {
        self.backoffNanoseconds = backoffNanoseconds
    }

    public var maximumAttempts: Int { backoffNanoseconds.count + 1 }
    public var maximumDelayMilliseconds: Int {
        Int(backoffNanoseconds.reduce(0, +) / 1_000_000)
    }
}

public struct DeviceApplicationInventory: Equatable, Sendable {
    public let selectedDeviceMatches: Bool
    public let bundleIdentifiers: Set<String>
    public let failureCode: ConsumerProvisioningErrorCode?
    public let safeReason: String

    public init(
        selectedDeviceMatches: Bool,
        bundleIdentifiers: Set<String>,
        failureCode: ConsumerProvisioningErrorCode? = nil,
        safeReason: String = "inventory available"
    ) {
        self.selectedDeviceMatches = selectedDeviceMatches
        self.bundleIdentifiers = bundleIdentifiers
        self.failureCode = failureCode
        self.safeReason = safeReason
    }

    public var available: Bool { failureCode == nil }
}

public protocol DeviceApplicationInventoryReading: Sendable {
    func read(rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> DeviceApplicationInventory
}

public struct DevicectlApplicationInventoryReader: DeviceApplicationInventoryReading {
    public init() {}

    public func read(
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async -> DeviceApplicationInventory {
        guard !RuntimeProvisioning.devicectlForbidden(), let xcrun = RuntimeProvisioning.xcrunURL() else {
            return DeviceApplicationInventory(
                selectedDeviceMatches: false,
                bundleIdentifiers: [],
                failureCode: .deviceUnavailable,
                safeReason: "authoritative inventory unavailable"
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-install-inventory-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return DeviceApplicationInventory(
                selectedDeviceMatches: true,
                bundleIdentifiers: [],
                failureCode: .installVerificationFailed,
                safeReason: "inventory workspace unavailable"
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("apps.json")
        guard let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl", "device", "info", "apps",
                "--device", rawDeviceIdentifier,
                "--timeout", "10",
                "--json-output", output.path,
                "--quiet"
            ],
            workingDirectory: root,
            environment: RuntimeProvisioning.deterministicEnvironment()
        ) else {
            return DeviceApplicationInventory(
                selectedDeviceMatches: false,
                bundleIdentifiers: [],
                failureCode: .deviceUnavailable,
                safeReason: "inventory command unavailable"
            )
        }
        guard result.exitCode == 0 else {
            let code = ConsumerProvisioningErrorClassifier.installErrorCode(
                output: result.combinedOutput,
                artifact: "main"
            )
            return DeviceApplicationInventory(
                selectedDeviceMatches: code != .deviceUnavailable,
                bundleIdentifiers: [],
                failureCode: code == .mainInstallFailure ? .installVerificationFailed : code,
                safeReason: code.rawValue
            )
        }
        guard let data = try? Data(contentsOf: output),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let apps = resultObject["apps"] as? [[String: Any]] else {
            return DeviceApplicationInventory(
                selectedDeviceMatches: true,
                bundleIdentifiers: [],
                failureCode: .installVerificationFailed,
                safeReason: "inventory result could not be parsed"
            )
        }
        return DeviceApplicationInventory(
            selectedDeviceMatches: true,
            bundleIdentifiers: Set(apps.compactMap { $0["bundleIdentifier"] as? String })
        )
    }
}
