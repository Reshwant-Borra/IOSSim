import CryptoKit
import Foundation

public enum AutomaticPairingState: String, Codable, Equatable, Sendable {
    case checkingUSB = "PAIRING_CHECKING_USB"
    case computerTrustRequired = "PAIRING_COMPUTER_TRUST_REQUIRED"
    case generating = "PAIRING_GENERATING"
    case validatingCandidate = "PAIRING_VALIDATING_CANDIDATE"
    case transferring = "PAIRING_TRANSFERRING"
    case verifyingOnDevice = "PAIRING_VERIFYING_ON_DEVICE"
    case ready = "PAIRING_READY"
    case failed = "PAIRING_FAILED"
}

public enum AutomaticPairingError: Error, Equatable, Sendable {
    case selectedDeviceRequired
    case staleOperation
    case helperUnavailable
    case generationFailed
    case candidateInvalid
    case transferFailed
    case onDeviceValidationFailed
    case receiptMismatch
}

public struct RPPairingCandidate: Equatable, Sendable {
    public let transactionID: UUID
    public let selectedDeviceHash: String
    public let generation: UInt64
    public let fileURL: URL

    public init(transactionID: UUID, selectedDeviceHash: String, generation: UInt64, fileURL: URL) {
        self.transactionID = transactionID
        self.selectedDeviceHash = selectedDeviceHash
        self.generation = generation
        self.fileURL = fileURL
    }
}

public struct AutomaticPairingReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let state: String

    public init(schemaVersion: Int = 1, transactionID: UUID, state: String) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.state = state
    }
}

public enum MacRPPairingValidator {
    public static func validate(_ data: Data) throws {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = root as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else {
            throw AutomaticPairingError.candidateInvalid
        }
        if let altIRK = plist["alt_irk"] as? Data, altIRK.count != 16 {
            throw AutomaticPairingError.candidateInvalid
        }
    }
}

public protocol RPPairingCandidateGenerating: Sendable {
    func generate(selectedDeviceIdentifier: String, generation: UInt64) async throws -> RPPairingCandidate
}

public struct BundledRPPairingHelper: RPPairingCandidateGenerating, @unchecked Sendable {
    private let helperURL: URL
    private let stagingRoot: URL
    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(
        helperURL: URL,
        stagingRoot: URL? = nil,
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.helperURL = helperURL
        self.stagingRoot = stagingRoot ?? fileManager.temporaryDirectory
            .appendingPathComponent("IOSSim-Pairing", isDirectory: true)
        self.runner = runner
        self.fileManager = fileManager
    }

    public func generate(selectedDeviceIdentifier: String, generation: UInt64) async throws -> RPPairingCandidate {
        guard !selectedDeviceIdentifier.isEmpty else { throw AutomaticPairingError.selectedDeviceRequired }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw AutomaticPairingError.helperUnavailable
        }
        let transactionID = UUID()
        let root = stagingRoot.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let candidateURL = root.appendingPathComponent("\(transactionID.uuidString).plist")
        let result = try await runner.run(
            executableURL: helperURL,
            arguments: [
                "create",
                "--udid", selectedDeviceIdentifier,
                "--hostname", "IOSSim",
                "--output", candidateURL.path
            ],
            workingDirectory: root,
            environment: RuntimeProvisioning.baseDeterministicEnvironment()
        )
        guard result.exitCode == 0, fileManager.fileExists(atPath: candidateURL.path) else {
            try? fileManager.removeItem(at: root)
            throw AutomaticPairingError.generationFailed
        }
        let data = try Data(contentsOf: candidateURL, options: .mappedIfSafe)
        do {
            try MacRPPairingValidator.validate(data)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
        return RPPairingCandidate(
            transactionID: transactionID,
            selectedDeviceHash: Self.hash(selectedDeviceIdentifier),
            generation: generation,
            fileURL: candidateURL
        )
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol RPPairingMaterialTransferring: Sendable {
    func transferAndVerify(
        candidate: RPPairingCandidate,
        selectedDeviceIdentifier: String,
        mainBundleIdentifier: String
    ) async throws -> AutomaticPairingReceipt
}

/// Transfers through CoreDevice's private app-data-container domain. This is
/// not House Arrest/AFC Documents sharing and does not expose the record in
/// Files. Only a non-secret receipt is copied back to the Mac.
public struct DevicectlRPPairingTransfer: RPPairingMaterialTransferring, @unchecked Sendable {
    private let runner: ProcessRunner
    private let fileManager: FileManager
    private let receiptAttempts: Int

    public init(runner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default, receiptAttempts: Int = 12) {
        self.runner = runner
        self.fileManager = fileManager
        self.receiptAttempts = receiptAttempts
    }

    public func transferAndVerify(
        candidate: RPPairingCandidate,
        selectedDeviceIdentifier: String,
        mainBundleIdentifier: String
    ) async throws -> AutomaticPairingReceipt {
        let environment = RuntimeProvisioning.deterministicEnvironment()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-pairing-receipt-\(candidate.transactionID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: candidate.fileURL.deletingLastPathComponent())
        }
        let copied = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "copy", "to",
                "--device", selectedDeviceIdentifier,
                "--domain-type", "appDataContainer",
                "--domain-identifier", mainBundleIdentifier,
                "--source", candidate.fileURL.path,
                "--destination", "Library/Application Support/IOSSim/PairingInbox",
                "--timeout", "30", "--quiet"
            ],
            workingDirectory: root,
            environment: environment
        )
        guard copied.exitCode == 0 else { throw AutomaticPairingError.transferFailed }

        let launched = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", selectedDeviceIdentifier,
                "--terminate-existing", mainBundleIdentifier,
                "--timeout", "30", "--quiet"
            ],
            workingDirectory: root,
            environment: environment
        )
        guard launched.exitCode == 0 else { throw AutomaticPairingError.transferFailed }

        for attempt in 0..<receiptAttempts {
            let output = root.appendingPathComponent("attempt-\(attempt)", isDirectory: true)
            let readback = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "device", "copy", "from",
                    "--device", selectedDeviceIdentifier,
                    "--domain-type", "appDataContainer",
                    "--domain-identifier", mainBundleIdentifier,
                    "--source", "Library/Application Support/IOSSim/PairingReceipts/\(candidate.transactionID.uuidString).json",
                    "--destination", output.path,
                    "--timeout", "15", "--quiet"
                ],
                workingDirectory: root,
                environment: environment
            )
            if readback.exitCode == 0,
               let receiptURL = firstJSON(in: output),
               let receipt = try? JSONDecoder().decode(AutomaticPairingReceipt.self, from: Data(contentsOf: receiptURL)) {
                guard receipt.transactionID == candidate.transactionID else {
                    throw AutomaticPairingError.receiptMismatch
                }
                guard receipt.state == AutomaticPairingState.ready.rawValue else {
                    throw AutomaticPairingError.onDeviceValidationFailed
                }
                return receipt
            }
            if attempt + 1 < receiptAttempts { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw AutomaticPairingError.onDeviceValidationFailed
    }

    private func firstJSON(in root: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { $0.pathExtension == "json" }
    }
}

public struct AutomaticRPPairingCoordinator: Sendable {
    private let generator: any RPPairingCandidateGenerating
    private let transfer: any RPPairingMaterialTransferring

    public init(generator: any RPPairingCandidateGenerating, transfer: any RPPairingMaterialTransferring) {
        self.generator = generator
        self.transfer = transfer
    }

    public func prepare(
        selectedDeviceIdentifier: String,
        mainBundleIdentifier: String,
        generation: UInt64,
        isCurrent: @escaping @Sendable (String, UInt64) async -> Bool
    ) async throws -> AutomaticPairingReceipt {
        guard !selectedDeviceIdentifier.isEmpty else { throw AutomaticPairingError.selectedDeviceRequired }
        guard await isCurrent(selectedDeviceIdentifier, generation) else { throw AutomaticPairingError.staleOperation }
        let candidate = try await generator.generate(
            selectedDeviceIdentifier: selectedDeviceIdentifier,
            generation: generation
        )
        guard candidate.generation == generation,
              candidate.selectedDeviceHash == Self.hash(selectedDeviceIdentifier),
              await isCurrent(selectedDeviceIdentifier, generation) else {
            try? FileManager.default.removeItem(at: candidate.fileURL.deletingLastPathComponent())
            throw AutomaticPairingError.staleOperation
        }
        let receipt = try await transfer.transferAndVerify(
            candidate: candidate,
            selectedDeviceIdentifier: selectedDeviceIdentifier,
            mainBundleIdentifier: mainBundleIdentifier
        )
        guard await isCurrent(selectedDeviceIdentifier, generation) else {
            throw AutomaticPairingError.staleOperation
        }
        return receipt
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
