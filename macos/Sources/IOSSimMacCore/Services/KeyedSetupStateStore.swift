import CryptoKit
import Darwin
import Foundation

public struct SetupIdentity: Equatable, Sendable {
    public let releaseIdentity: String
    public let teamIdentifier: String
    public let deviceIdentifier: String
    public let artifactSetIdentity: String

    public init(
        releaseIdentity: String,
        teamIdentifier: String,
        deviceIdentifier: String,
        artifactSetIdentity: String
    ) throws {
        guard !releaseIdentity.isEmpty, !teamIdentifier.isEmpty,
              !deviceIdentifier.isEmpty, !artifactSetIdentity.isEmpty else {
            throw SetupStateError.unsafeState("setup identity contains an empty component")
        }
        self.releaseIdentity = releaseIdentity
        self.teamIdentifier = teamIdentifier
        self.deviceIdentifier = deviceIdentifier
        self.artifactSetIdentity = artifactSetIdentity
    }

    public var key: String {
        Self.digest([releaseIdentity, teamIdentifier, deviceIdentifier, artifactSetIdentity])
    }

    public static func provisioning(
        manifest: ArtifactManifest,
        teamIdentifier: String,
        deviceIdentifier: String
    ) throws -> SetupIdentity {
        let release = [
            manifest.release.sourceCommit,
            manifest.release.macVersion,
            manifest.release.buildNumber ?? "",
            String(manifest.release.helperSchemaVersion),
            manifest.release.variant ?? ""
        ].joined(separator: "\u{1f}")
        let artifacts = manifest.components
            .sorted { ($0.role, $0.bundleIdentifier) < ($1.role, $1.bundleIdentifier) }
            .map { [$0.role, $0.bundleIdentifier, $0.version, $0.sha256].joined(separator: "\u{1f}") }
            .joined(separator: "\u{1e}")
        return try SetupIdentity(
            releaseIdentity: release,
            teamIdentifier: teamIdentifier,
            deviceIdentifier: deviceIdentifier,
            artifactSetIdentity: "schema=\(manifest.schemaVersion)\u{1e}\(artifacts)"
        )
    }

    var releaseHash: String { Self.digest([releaseIdentity]) }
    var teamHash: String { Self.digest([teamIdentifier]) }
    var deviceHash: String { Self.digest([deviceIdentifier]) }
    var artifactSetHash: String { Self.digest([artifactSetIdentity]) }

    private static func digest(_ values: [String]) -> String {
        var hasher = SHA256()
        for value in values {
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum SetupStateError: Error, Equatable, Sendable, CustomStringConvertible {
    case leaseHeld
    case staleGeneration(expected: UInt64, actual: UInt64)
    case corruptSnapshot
    case corruptJournal
    case unsafeState(String)
    case unsupportedSchema(Int)
    case noInterruptedOperation

    public var code: String {
        switch self {
        case .leaseHeld: return "VEYA-STATE-001"
        case .staleGeneration: return "VEYA-STATE-002"
        case .corruptSnapshot: return "VEYA-STATE-003"
        case .corruptJournal: return "VEYA-STATE-004"
        case .unsafeState: return "VEYA-STATE-005"
        case .unsupportedSchema: return "VEYA-UPDATE-003"
        case .noInterruptedOperation: return "VEYA-STATE-006"
        }
    }

    public var description: String {
        switch self {
        case .leaseHeld:
            return "\(code): Another IOSSim setup operation is already changing this device/team/release state."
        case .staleGeneration(let expected, let actual):
            return "\(code): Setup state generation is stale (expected \(expected), actual \(actual))."
        case .corruptSnapshot:
            return "\(code): Setup snapshot is corrupt and was not used."
        case .corruptJournal:
            return "\(code): Setup journal integrity validation failed and mutation was stopped."
        case .unsafeState(let detail):
            return "\(code): Unsafe setup state was rejected: \(detail)."
        case .unsupportedSchema(let schema):
            return "\(code): Setup state schema \(schema) is newer than this IOSSim version."
        case .noInterruptedOperation:
            return "\(code): No interrupted setup mutation is available to recover."
        }
    }
}

public struct SetupStateSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let setupKey: String
    public let generation: UInt64
    public let releaseIdentityHash: String
    public let teamIdentityHash: String
    public let deviceIdentityHash: String
    public let artifactSetIdentityHash: String
    public let lastOperationID: String?
    public let lastDomain: String?
    public let legacyManifestSHA256: String?
    public let updatedAt: Date
}

public enum SetupJournalPhase: String, Codable, Equatable, Sendable {
    case intent = "INTENT"
    case observed = "OBSERVED"
    case committed = "COMMITTED"
    case abandoned = "ABANDONED"
    case leaseRecovered = "LEASE_RECOVERED"
    case migrated = "MIGRATED"
}

public struct SetupOperationJournalEntry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sequence: UInt64
    public let operationID: String
    public let setupKey: String
    public let expectedGeneration: UInt64
    public let resultingGeneration: UInt64?
    public let phase: SetupJournalPhase
    public let domain: String
    public let safeDetail: String?
    public let timestamp: Date
    public let previousHash: String?
    public let entryHash: String
}

public struct SetupMutationResult<Value: Sendable>: Sendable {
    public let value: Value
    public let snapshot: SetupStateSnapshot
}

private struct SetupLeaseRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let processID: Int32
    let processStartToken: String
    let operationID: String
    let acquiredAt: Date
    let heartbeatAt: Date
    let bootSession: String
    let generation: UInt64
}

private final class SetupFileLease: @unchecked Sendable {
    private let descriptor: Int32
    private let recordURL: URL
    private let lock = NSLock()
    private var released = false

    init(descriptor: Int32, recordURL: URL) {
        self.descriptor = descriptor
        self.recordURL = recordURL
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        _ = unlink(recordURL.path)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit { release() }
}

public actor KeyedSetupStateStore {
    public static let snapshotFileName = "snapshot-v5.json"
    public static let journalFileName = "journal-v1.jsonl"
    public static let leaseRecordFileName = "lease.json"
    public static let leaseLockFileName = "lease.lock"

    private static let processStartToken = UUID().uuidString
    private let rootURL: URL
    private let fileManager: FileManager

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("IOSSim", isDirectory: true)
            .appendingPathComponent("SetupState", isDirectory: true)
    }

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = Self.defaultRootURL(fileManager: fileManager)
        }
    }

    public nonisolated func directory(for identity: SetupIdentity) -> URL {
        rootURL.appendingPathComponent(identity.key, isDirectory: true)
    }

    public func load(identity: SetupIdentity) throws -> SetupStateSnapshot {
        let directory = directory(for: identity)
        _ = try loadJournal(directory: directory, expectedKey: identity.key)
        return try loadSnapshot(identity: identity, directory: directory)
    }

    public func journal(identity: SetupIdentity) throws -> [SetupOperationJournalEntry] {
        try loadJournal(directory: directory(for: identity), expectedKey: identity.key)
    }

    public func withMutation<Value: Sendable>(
        identity: SetupIdentity,
        expectedGeneration: UInt64? = nil,
        domain: String,
        safeDetail: String? = nil,
        legacyManifestSHA256: String? = nil,
        operation: @Sendable (String) async throws -> Value
    ) async throws -> SetupMutationResult<Value> {
        try validateSafe(domain, field: "domain", maximumLength: 96)
        if let safeDetail { try validateSafe(safeDetail, field: "detail", maximumLength: 512) }
        let directory = directory(for: identity)
        try ensureDirectory(directory)
        let operationID = UUID().uuidString.lowercased()
        let lease = try acquireLease(
            directory: directory,
            operationID: operationID,
            generation: expectedGeneration ?? 0,
            setupKey: identity.key
        )
        defer { lease.release() }

        let existingJournal = try loadJournal(directory: directory, expectedKey: identity.key)
        let current = try loadSnapshot(identity: identity, directory: directory)
        if let expectedGeneration, expectedGeneration != current.generation {
            throw SetupStateError.staleGeneration(expected: expectedGeneration, actual: current.generation)
        }
        try append(
            phase: .intent,
            identity: identity,
            operationID: operationID,
            expectedGeneration: current.generation,
            resultingGeneration: nil,
            domain: domain,
            safeDetail: safeDetail,
            directory: directory,
            existing: existingJournal
        )

        let value = try await operation(operationID)
        var journal = try loadJournal(directory: directory, expectedKey: identity.key)
        try append(
            phase: .observed,
            identity: identity,
            operationID: operationID,
            expectedGeneration: current.generation,
            resultingGeneration: nil,
            domain: domain,
            safeDetail: safeDetail,
            directory: directory,
            existing: journal
        )
        journal = try loadJournal(directory: directory, expectedKey: identity.key)
        let committed = snapshot(
            identity: identity,
            generation: current.generation + 1,
            operationID: operationID,
            domain: domain,
            legacyManifestSHA256: legacyManifestSHA256 ?? current.legacyManifestSHA256
        )
        try compareAndSwapSnapshot(
            committed,
            expectedGeneration: current.generation,
            identity: identity,
            directory: directory
        )
        try append(
            phase: .committed,
            identity: identity,
            operationID: operationID,
            expectedGeneration: current.generation,
            resultingGeneration: committed.generation,
            domain: domain,
            safeDetail: safeDetail,
            directory: directory,
            existing: journal
        )
        return SetupMutationResult(value: value, snapshot: committed)
    }

    public func recoverInterrupted(
        identity: SetupIdentity,
        effectObserved: Bool,
        safeDetail: String
    ) throws -> SetupStateSnapshot {
        try validateSafe(safeDetail, field: "recovery detail", maximumLength: 512)
        let directory = directory(for: identity)
        try ensureDirectory(directory)
        let recoveryOperationID = UUID().uuidString.lowercased()
        let lease = try acquireLease(
            directory: directory,
            operationID: recoveryOperationID,
            generation: 0,
            setupKey: identity.key
        )
        defer { lease.release() }
        var journal = try loadJournal(directory: directory, expectedKey: identity.key)
        guard let intent = interruptedIntent(in: journal) else {
            throw SetupStateError.noInterruptedOperation
        }
        let current = try loadSnapshot(identity: identity, directory: directory)
        if current.generation == intent.expectedGeneration + 1,
           current.lastOperationID == intent.operationID {
            try append(
                phase: .committed,
                identity: identity,
                operationID: intent.operationID,
                expectedGeneration: intent.expectedGeneration,
                resultingGeneration: current.generation,
                domain: intent.domain,
                safeDetail: "Recovered the durable snapshot after an interrupted journal commit.",
                directory: directory,
                existing: journal
            )
            return current
        }
        guard current.generation == intent.expectedGeneration else {
            throw SetupStateError.staleGeneration(
                expected: intent.expectedGeneration,
                actual: current.generation
            )
        }
        if !effectObserved {
            try append(
                phase: .abandoned,
                identity: identity,
                operationID: intent.operationID,
                expectedGeneration: current.generation,
                resultingGeneration: current.generation,
                domain: intent.domain,
                safeDetail: safeDetail,
                directory: directory,
                existing: journal
            )
            return current
        }
        try append(
            phase: .observed,
            identity: identity,
            operationID: intent.operationID,
            expectedGeneration: current.generation,
            resultingGeneration: nil,
            domain: intent.domain,
            safeDetail: safeDetail,
            directory: directory,
            existing: journal
        )
        journal = try loadJournal(directory: directory, expectedKey: identity.key)
        let committed = snapshot(
            identity: identity,
            generation: current.generation + 1,
            operationID: intent.operationID,
            domain: intent.domain,
            legacyManifestSHA256: current.legacyManifestSHA256
        )
        try compareAndSwapSnapshot(
            committed,
            expectedGeneration: current.generation,
            identity: identity,
            directory: directory
        )
        try append(
            phase: .committed,
            identity: identity,
            operationID: intent.operationID,
            expectedGeneration: current.generation,
            resultingGeneration: committed.generation,
            domain: intent.domain,
            safeDetail: safeDetail,
            directory: directory,
            existing: journal
        )
        return committed
    }

    public func importLegacyManifest(
        _ data: Data,
        identity: SetupIdentity,
        expectedGeneration: UInt64? = nil
    ) async throws -> SetupStateSnapshot {
        let manifest: ConsumerProvisioningManifest
        do {
            manifest = try JSONDecoder.setupState.decode(ConsumerProvisioningManifest.self, from: data)
        } catch {
            do {
                // Some schema-1 fixtures predate the ISO-8601 state encoder. Accept
                // those only for one-way migration; all V5 state is rewritten using
                // the canonical encoder below.
                manifest = try JSONDecoder().decode(ConsumerProvisioningManifest.self, from: data)
            } catch {
                throw SetupStateError.corruptSnapshot
            }
        }
        guard (1...ConsumerProvisioningManifest.currentSchemaVersion).contains(manifest.schemaVersion) else {
            throw SetupStateError.unsupportedSchema(manifest.schemaVersion)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let result: SetupMutationResult<Bool> = try await withMutation(
            identity: identity,
            expectedGeneration: expectedGeneration,
            domain: "schema4Import",
            safeDetail: "Imported legacy provisioning metadata by digest.",
            legacyManifestSHA256: digest
        ) { _ in true }
        return result.snapshot
    }

    private func acquireLease(
        directory: URL,
        operationID: String,
        generation: UInt64,
        setupKey: String
    ) throws -> SetupFileLease {
        let lockURL = directory.appendingPathComponent(Self.leaseLockFileName)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SetupStateError.unsafeState("lease file could not be opened") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw SetupStateError.leaseHeld
        }
        let recordURL = directory.appendingPathComponent(Self.leaseRecordFileName)
        let staleLeasePresent = fileManager.fileExists(atPath: recordURL.path)
        let record = SetupLeaseRecord(
            schemaVersion: 1,
            processID: ProcessInfo.processInfo.processIdentifier,
            processStartToken: Self.processStartToken,
            operationID: operationID,
            acquiredAt: .now,
            heartbeatAt: .now,
            bootSession: String(Int(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)),
            generation: generation
        )
        do {
            try atomicWrite(try JSONEncoder.setupState.encode(record), to: recordURL, directory: directory)
            if staleLeasePresent {
                let journal = try loadJournal(directory: directory, expectedKey: setupKey)
                let placeholderIdentity = try SetupIdentity(
                    releaseIdentity: "lease-recovery",
                    teamIdentifier: "lease-recovery",
                    deviceIdentifier: "lease-recovery",
                    artifactSetIdentity: "lease-recovery"
                )
                try append(
                    phase: .leaseRecovered,
                    identity: placeholderIdentity,
                    setupKeyOverride: setupKey,
                    operationID: operationID,
                    expectedGeneration: generation,
                    resultingGeneration: generation,
                    domain: "lease",
                    safeDetail: "Recovered an OS-unlocked stale lease record.",
                    directory: directory,
                    existing: journal
                )
            }
            return SetupFileLease(descriptor: descriptor, recordURL: recordURL)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw error
        }
    }

    private func loadSnapshot(identity: SetupIdentity, directory: URL) throws -> SetupStateSnapshot {
        let url = directory.appendingPathComponent(Self.snapshotFileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return snapshot(
                identity: identity,
                generation: 0,
                operationID: nil,
                domain: nil,
                legacyManifestSHA256: nil
            )
        }
        let value: SetupStateSnapshot
        do {
            value = try JSONDecoder.setupState.decode(SetupStateSnapshot.self, from: Data(contentsOf: url))
        } catch {
            throw SetupStateError.corruptSnapshot
        }
        guard value.schemaVersion <= SetupStateSnapshot.currentSchemaVersion else {
            throw SetupStateError.unsupportedSchema(value.schemaVersion)
        }
        guard value.schemaVersion == SetupStateSnapshot.currentSchemaVersion,
              value.setupKey == identity.key,
              value.releaseIdentityHash == identity.releaseHash,
              value.teamIdentityHash == identity.teamHash,
              value.deviceIdentityHash == identity.deviceHash,
              value.artifactSetIdentityHash == identity.artifactSetHash else {
            throw SetupStateError.corruptSnapshot
        }
        return value
    }

    private func compareAndSwapSnapshot(
        _ snapshot: SetupStateSnapshot,
        expectedGeneration: UInt64,
        identity: SetupIdentity,
        directory: URL
    ) throws {
        let current = try loadSnapshot(identity: identity, directory: directory)
        guard current.generation == expectedGeneration else {
            throw SetupStateError.staleGeneration(expected: expectedGeneration, actual: current.generation)
        }
        let url = directory.appendingPathComponent(Self.snapshotFileName)
        try atomicWrite(try JSONEncoder.setupState.encode(snapshot), to: url, directory: directory)
    }

    private func snapshot(
        identity: SetupIdentity,
        generation: UInt64,
        operationID: String?,
        domain: String?,
        legacyManifestSHA256: String?
    ) -> SetupStateSnapshot {
        SetupStateSnapshot(
            schemaVersion: SetupStateSnapshot.currentSchemaVersion,
            setupKey: identity.key,
            generation: generation,
            releaseIdentityHash: identity.releaseHash,
            teamIdentityHash: identity.teamHash,
            deviceIdentityHash: identity.deviceHash,
            artifactSetIdentityHash: identity.artifactSetHash,
            lastOperationID: operationID,
            lastDomain: domain,
            legacyManifestSHA256: legacyManifestSHA256,
            updatedAt: .now
        )
    }

    private func loadJournal(directory: URL, expectedKey: String) throws -> [SetupOperationJournalEntry] {
        let url = directory.appendingPathComponent(Self.journalFileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1_024 * 1_024,
              let text = String(data: data, encoding: .utf8) else {
            throw SetupStateError.corruptJournal
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [SetupOperationJournalEntry] = []
        var priorHash: String?
        for (index, line) in lines.enumerated() {
            guard line.utf8.count <= 65_536,
                  let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder.setupState.decode(SetupOperationJournalEntry.self, from: lineData),
                  entry.schemaVersion == SetupOperationJournalEntry.currentSchemaVersion,
                  entry.sequence == UInt64(index + 1),
                  entry.setupKey == expectedKey,
                  entry.previousHash == priorHash,
                  entry.entryHash == journalHash(entry) else {
                throw SetupStateError.corruptJournal
            }
            entries.append(entry)
            priorHash = entry.entryHash
        }
        return entries
    }

    private func append(
        phase: SetupJournalPhase,
        identity: SetupIdentity,
        setupKeyOverride: String? = nil,
        operationID: String,
        expectedGeneration: UInt64,
        resultingGeneration: UInt64?,
        domain: String,
        safeDetail: String?,
        directory: URL,
        existing: [SetupOperationJournalEntry]
    ) throws {
        let unhashed = SetupOperationJournalEntry(
            schemaVersion: SetupOperationJournalEntry.currentSchemaVersion,
            sequence: UInt64(existing.count + 1),
            operationID: operationID,
            setupKey: setupKeyOverride ?? identity.key,
            expectedGeneration: expectedGeneration,
            resultingGeneration: resultingGeneration,
            phase: phase,
            domain: domain,
            safeDetail: safeDetail,
            timestamp: .now,
            previousHash: existing.last?.entryHash,
            entryHash: ""
        )
        let entry = SetupOperationJournalEntry(
            schemaVersion: unhashed.schemaVersion,
            sequence: unhashed.sequence,
            operationID: unhashed.operationID,
            setupKey: unhashed.setupKey,
            expectedGeneration: unhashed.expectedGeneration,
            resultingGeneration: unhashed.resultingGeneration,
            phase: unhashed.phase,
            domain: unhashed.domain,
            safeDetail: unhashed.safeDetail,
            timestamp: unhashed.timestamp,
            previousHash: unhashed.previousHash,
            entryHash: journalHash(unhashed)
        )
        var data = try JSONEncoder.setupState.encode(entry)
        data.append(0x0A)
        let url = directory.appendingPathComponent(Self.journalFileName)
        let descriptor = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SetupStateError.unsafeState("journal could not be opened") }
        defer { _ = close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw SetupStateError.unsafeState("journal append failed") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SetupStateError.unsafeState("journal fsync failed")
        }
        try fsyncDirectory(directory)
    }

    private func interruptedIntent(in journal: [SetupOperationJournalEntry]) -> SetupOperationJournalEntry? {
        let terminal: Set<SetupJournalPhase> = [.committed, .abandoned]
        for entry in journal.reversed() where entry.phase == .intent {
            let completed = journal.contains {
                $0.operationID == entry.operationID && terminal.contains($0.phase)
            }
            if !completed { return entry }
        }
        return nil
    }

    private func journalHash(_ entry: SetupOperationJournalEntry) -> String {
        struct HashPayload: Encodable {
            let schemaVersion: Int
            let sequence: UInt64
            let operationID: String
            let setupKey: String
            let expectedGeneration: UInt64
            let resultingGeneration: UInt64?
            let phase: SetupJournalPhase
            let domain: String
            let safeDetail: String?
            let timestamp: Date
            let previousHash: String?
        }
        let payload = HashPayload(
            schemaVersion: entry.schemaVersion,
            sequence: entry.sequence,
            operationID: entry.operationID,
            setupKey: entry.setupKey,
            expectedGeneration: entry.expectedGeneration,
            resultingGeneration: entry.resultingGeneration,
            phase: entry.phase,
            domain: entry.domain,
            safeDetail: entry.safeDetail,
            timestamp: entry.timestamp,
            previousHash: entry.previousHash
        )
        let data = (try? JSONEncoder.setupState.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to url: URL, directory: URL) throws {
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SetupStateError.unsafeState("temporary state file could not be created") }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw SetupStateError.unsafeState("state write failed") }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else { throw SetupStateError.unsafeState("state fsync failed") }
            _ = close(descriptor)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw SetupStateError.unsafeState("atomic state rename failed")
            }
            try fsyncDirectory(directory)
        } catch {
            _ = close(descriptor)
            _ = unlink(temporary.path)
            throw error
        }
    }

    private func ensureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw SetupStateError.unsafeState("state directory could not be opened") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SetupStateError.unsafeState("state directory fsync failed") }
    }

    private func validateSafe(_ value: String, field: String, maximumLength: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
              !value.contains("\n"), !value.contains("\r") else {
            throw SetupStateError.unsafeState("\(field) is invalid")
        }
        let lower = value.lowercased()
        guard !Self.forbiddenFragments.contains(where: lower.contains) else {
            throw SetupStateError.unsafeState("\(field) contains secret-shaped data")
        }
    }

    private static let forbiddenFragments = [
        "password", "2fa", "verificationcode", "bearer ", "cookie",
        "privatekey", "private_key", "pairingdata", "pairing_data", "psk", "sessiontoken"
    ]
}

extension JSONEncoder {
    fileprivate static var setupState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var setupState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
