import CryptoKit
import Darwin
import Foundation

private struct InstallationJournalEnvelope: Codable {
    let schemaVersion: Int
    let digest: String
    let payload: InstallationJournal
}

public actor InstallationJournalRepository {
    public static let journalFileName = "journal-v1.json"
    public static let previousFileName = "journal-v1.previous.json"
    public static let lockFileName = "journal-v1.lock"

    public nonisolated let rootURL: URL
    public nonisolated var journalURL: URL { rootURL.appendingPathComponent(Self.journalFileName) }
    public nonisolated var previousURL: URL { rootURL.appendingPathComponent(Self.previousFileName) }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let faultInjector: @Sendable (JournalWritePoint) throws -> Void

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("Veya", isDirectory: true)
            .appendingPathComponent("installation", isDirectory: true)
    }

    public init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        faultInjector: @escaping @Sendable (JournalWritePoint) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.now = now
        self.faultInjector = faultInjector
    }

    @discardableResult
    public func initialize(installationID: UUID = UUID()) throws -> InstallationJournal {
        try ensureDirectory()
        return try withFileLock(exclusive: true) {
            if fileManager.fileExists(atPath: journalURL.path) {
                return try loadUnlocked()
            }
            let journal = InstallationJournal(installationID: installationID, now: now())
            try validate(journal)
            return try writeUnlocked(journal, preservePrevious: false)
        }
    }

    public func load() throws -> InstallationJournal {
        // Read-only callers must not create the directory or lock file for an installation that does not exist.
        guard fileManager.fileExists(atPath: journalURL.path) || fileManager.fileExists(atPath: previousURL.path) else {
            throw InstallationStateFailure.missingJournal
        }
        try ensureDirectory()
        return try withFileLock(exclusive: false) { try loadUnlocked() }
    }

    public func acquireLease(runID: RunID, duration: TimeInterval = 30) throws -> InstallationJournal {
        guard duration > 0, duration <= 300 else { throw InstallationStateFailure.unsafeValue("lease duration") }
        return try transact(expectedRevision: nil, expectedGeneration: nil, runID: nil) { journal, currentTime in
            if let lease = journal.lease, lease.runID != runID, !lease.isExpired(at: currentTime) {
                throw InstallationStateFailure.leaseHeld(lease.runID)
            }
            if let lease = journal.lease, lease.runID != runID, lease.isExpired(at: currentTime) {
                journal.recovery = JournalRecovery(
                    required: true,
                    reason: "staleLeaseRecovered",
                    recoveredFromRevision: journal.revision
                )
            }
            journal.lease = InstallationLease(
                runID: runID,
                ownerProcessID: getpid(),
                acquiredAt: currentTime,
                expiresAt: currentTime.addingTimeInterval(duration)
            )
        }
    }

    public func renewLease(runID: RunID, duration: TimeInterval = 30) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, currentTime in
            guard var lease = journal.lease, lease.runID == runID else {
                throw InstallationStateFailure.leaseNotOwned
            }
            lease.expiresAt = currentTime.addingTimeInterval(duration)
            journal.lease = lease
        }
    }

    public func releaseLease(runID: RunID) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, _ in
            guard journal.lease?.runID == runID else { throw InstallationStateFailure.leaseNotOwned }
            journal.lease = nil
        }
    }

    public func putCandidate(
        _ candidate: ResourceRecord,
        runID: RunID,
        expectedGeneration: Generation
    ) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: expectedGeneration, runID: runID) { journal, _ in
            let next = try journal.generation.advanced()
            guard candidate.lifecycle == .candidate, candidate.generation == next else {
                throw InstallationStateFailure.staleGeneration(expected: next, actual: candidate.generation)
            }
            try Self.executeBlockingCandidateRecovery(&journal, advancingTo: next, for: candidate.identity.domain)
            journal.generation = next
            journal.candidates[candidate.identity.domain.rawValue] = candidate
        }
    }

    /// Advancing the generation leaves any candidate from the previous one in violation of the journal
    /// invariant (`validate`), so the write would fail and no domain could ever be repaired again
    /// (physically observed: an unproved `runtime` candidate deadlocked every later run with
    /// `VEYA-SEC-003`). The planner already records what may be undone for such a candidate, so this
    /// performs exactly that rollback and nothing wider: only a domain whose create/replace recovery is
    /// `.rollback(.discardCandidate)` is Veya-local, and discarding one leaves its active record and any
    /// external resource untouched. A candidate whose creation had an irreversible effect (certificate,
    /// profile, application, developer support, pairing, VPN) is never discarded here; it is reported so
    /// it can be reconciled. The discard is recorded in `recovery`, never silent.
    private static func executeBlockingCandidateRecovery(
        _ journal: inout InstallationJournal,
        advancingTo next: Generation,
        for domain: InstallationDomain
    ) throws {
        let blocking = journal.candidates.filter { $0.key != domain.rawValue && $0.value.generation != next }
        guard !blocking.isEmpty else { return }
        for (_, record) in blocking {
            guard TransitionRecovery.required(domain: record.identity.domain, kind: .createCandidate)
                == .rollback(.discardCandidate) else {
                throw InstallationStateFailure.candidateUnproved(record.identity.domain)
            }
        }
        for key in blocking.keys { journal.candidates.removeValue(forKey: key) }
        journal.recovery = JournalRecovery(
            required: false,
            reason: String(("blockingCandidateDiscarded:" + blocking.keys.sorted().joined(separator: ",")).prefix(128)),
            recoveredFromRevision: journal.revision
        )
    }

    public func attachEvidence(_ item: Evidence, runID: RunID) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: item.generation, runID: runID) { journal, _ in
            let key = item.subject.domain.rawValue
            guard var candidate = journal.candidates[key], candidate.generation == item.generation else {
                throw InstallationStateFailure.candidateMissing(item.subject.domain)
            }
            guard !journal.evidence.contains(where: { $0.id == item.id }) else { return }
            journal.evidence.append(item)
            candidate.evidenceIDs.append(item.id)
            journal.candidates[key] = candidate
        }
    }

    public func promote(
        domain: InstallationDomain,
        runID: RunID,
        expectedGeneration: Generation
    ) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: expectedGeneration, runID: runID) { journal, _ in
            let key = domain.rawValue
            guard var candidate = journal.candidates[key] else {
                throw InstallationStateFailure.candidateMissing(domain)
            }
            let proofExists = candidate.evidenceIDs.contains { evidenceID in
                journal.evidence.contains {
                    $0.id == evidenceID && $0.generation == candidate.generation && $0.subject.domain == domain
                }
            }
            guard proofExists else { throw InstallationStateFailure.candidateUnproved(domain) }
            if var oldActive = journal.active[key] {
                oldActive.lifecycle = .retiring
                journal.retiring[key, default: []].append(oldActive)
            }
            candidate.lifecycle = .active
            journal.active[key] = candidate
            journal.candidates.removeValue(forKey: key)
            Self.applyRetention(&journal)
        }
    }

    /// Retiring signing keys are kept forever: their SPKI digests are the only proof that a certificate
    /// belongs to this installation (M6). Other domains keep a short rollback history, and evidence is
    /// kept only while a retained record references it, so periodic re-proofs cannot grow the journal.
    static let retainedRetiringRecords = 4
    static func applyRetention(_ journal: inout InstallationJournal) {
        for (key, records) in journal.retiring where key != InstallationDomain.signingKey.rawValue {
            journal.retiring[key] = Array(records.suffix(retainedRetiringRecords))
        }
        let referenced = Set(
            (Array(journal.active.values) + Array(journal.candidates.values) + journal.retiring.values.flatMap { $0 })
                .flatMap(\.evidenceIDs)
        )
        journal.evidence.removeAll { !referenced.contains($0.id) }
    }

    public func discardCandidate(
        domain: InstallationDomain,
        runID: RunID,
        expectedGeneration: Generation
    ) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: expectedGeneration, runID: runID) { journal, _ in
            guard journal.candidates.removeValue(forKey: domain.rawValue) != nil else {
                throw InstallationStateFailure.candidateMissing(domain)
            }
        }
    }

    public func updateMigration(
        runID: RunID,
        phase: MigrationLedger.Phase,
        items: [String: String]
    ) throws -> InstallationJournal {
        try InstallationSafeValue.validate(attributes: items)
        return try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, _ in
            journal.migration = MigrationLedger(phase: phase, items: items)
        }
    }

    public func beginTransition(
        _ transition: JournalTransition,
        expectedGeneration: Generation,
        runID: RunID
    ) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: expectedGeneration, runID: runID) { journal, _ in
            guard journal.transition == nil else { throw InstallationStateFailure.transitionInProgress }
            guard transition.runID == runID, transition.phase == .planned else {
                throw InstallationStateFailure.unsafeValue("transition start")
            }
            journal.transition = transition
        }
    }

    /// Clears a transition left by a run that died or lost its lease. External truth is re-observed
    /// afterwards; the candidate (if any) is preserved for proof or replacement by the planner.
    public func recoverAbandonedTransition(runID: RunID) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, _ in
            guard journal.transition != nil else { return }
            journal.recovery = JournalRecovery(
                required: true,
                reason: "abandonedTransitionRecovered",
                recoveredFromRevision: journal.revision
            )
            journal.transition = nil
        }
    }

    public func updateTransitionPhase(
        _ phase: JournalTransition.Phase,
        runID: RunID
    ) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, _ in
            guard var transition = journal.transition, transition.runID == runID else {
                throw InstallationStateFailure.transitionMissing
            }
            transition.phase = phase
            journal.transition = transition
        }
    }

    public func clearTransition(runID: RunID) throws -> InstallationJournal {
        try transact(expectedRevision: nil, expectedGeneration: nil, runID: runID) { journal, _ in
            guard journal.transition?.runID == runID else {
                throw InstallationStateFailure.transitionMissing
            }
            journal.transition = nil
        }
    }

    private func transact(
        expectedRevision: UInt64?,
        expectedGeneration: Generation?,
        runID: RunID?,
        mutation: (inout InstallationJournal, Date) throws -> Void
    ) throws -> InstallationJournal {
        try ensureDirectory()
        return try withFileLock(exclusive: true) {
            var journal = try loadUnlocked()
            if let expectedRevision, journal.revision != expectedRevision {
                throw InstallationStateFailure.staleRevision(expected: expectedRevision, actual: journal.revision)
            }
            if let expectedGeneration, journal.generation != expectedGeneration {
                throw InstallationStateFailure.staleGeneration(expected: expectedGeneration, actual: journal.generation)
            }
            if let runID {
                guard let lease = journal.lease, lease.runID == runID, !lease.isExpired(at: now()) else {
                    throw InstallationStateFailure.leaseNotOwned
                }
            }
            let priorDigest = try digestPayload(journal)
            let priorRevision = journal.revision
            let priorGeneration = journal.generation
            let currentTime = now()
            try mutation(&journal, currentTime)
            guard journal.revision < UInt64.max else { throw InstallationStateFailure.generationOverflow }
            journal.revision += 1
            journal.updatedAt = currentTime
            journal.lastSafeCheckpoint = SafeCheckpoint(
                revision: priorRevision,
                generation: priorGeneration,
                digest: priorDigest
            )
            try validate(journal)
            return try writeUnlocked(journal, preservePrevious: true)
        }
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(rootURL.path, 0o700) == 0 else {
                throw InstallationStateFailure.writeFailed("directoryPermissions")
            }
        } catch let failure as InstallationStateFailure {
            throw failure
        } catch {
            throw InstallationStateFailure.writeFailed("createDirectory")
        }
    }

    private func withFileLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let lockURL = rootURL.appendingPathComponent(Self.lockFileName)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InstallationStateFailure.lockUnavailable }
        defer { _ = close(descriptor) }
        let operation = exclusive ? (LOCK_EX | LOCK_NB) : LOCK_SH
        guard flock(descriptor, operation) == 0 else { throw InstallationStateFailure.lockUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func loadUnlocked() throws -> InstallationJournal {
        guard fileManager.fileExists(atPath: journalURL.path) else {
            throw InstallationStateFailure.missingJournal
        }
        do {
            return try normalized(decodeEnvelope(Data(contentsOf: journalURL)))
        } catch {
            guard fileManager.fileExists(atPath: previousURL.path),
                  var recovered = try? normalized(decodeEnvelope(Data(contentsOf: previousURL))) else {
                throw InstallationStateFailure.corruptJournal
            }
            recovered.recovery = JournalRecovery(
                required: true,
                reason: "primaryJournalInvalid",
                recoveredFromRevision: recovered.revision
            )
            return recovered
        }
    }

    private func normalized(_ journal: InstallationJournal) throws -> InstallationJournal {
        if journal.schemaVersion > InstallationJournal.currentSchemaVersion {
            throw InstallationStateFailure.unsupportedSchema(journal.schemaVersion)
        }
        var value = journal
        if value.schemaVersion < InstallationJournal.currentSchemaVersion {
            value.schemaVersion = InstallationJournal.currentSchemaVersion
            value.recovery = JournalRecovery(
                required: true,
                reason: "schemaMigrated",
                recoveredFromRevision: value.revision
            )
        }
        try validate(value)
        return value
    }

    private func validate(_ journal: InstallationJournal) throws {
        guard journal.schemaVersion == InstallationJournal.currentSchemaVersion else {
            throw InstallationStateFailure.unsupportedSchema(journal.schemaVersion)
        }
        if let lease = journal.lease, lease.expiresAt <= lease.acquiredAt {
            throw InstallationStateFailure.unsafeValue("lease")
        }
        for (domain, record) in journal.active {
            guard domain == record.identity.domain.rawValue, record.lifecycle == .active else {
                throw InstallationStateFailure.unsafeValue("active resource")
            }
        }
        for (domain, record) in journal.candidates {
            guard domain == record.identity.domain.rawValue, record.lifecycle == .candidate,
                  record.generation == journal.generation else {
                throw InstallationStateFailure.unsafeValue("candidate resource")
            }
        }
        try InstallationSafeValue.validate(attributes: journal.migration.items)
        if let reason = journal.recovery.reason {
            try InstallationSafeValue.validate(reason, field: "recovery reason", maximumLength: 128)
        }
    }

    /// Writes atomically and returns the journal exactly as persisted. Dates are stored at millisecond
    /// precision, so verification compares payload digests and callers receive the decoded document.
    private func writeUnlocked(_ journal: InstallationJournal, preservePrevious: Bool) throws -> InstallationJournal {
        if preservePrevious, fileManager.fileExists(atPath: journalURL.path) {
            let prior = try Data(contentsOf: journalURL)
            try writeDataAtomically(prior, destination: previousURL, injectFaults: false)
        }
        let envelope = try encodeEnvelope(journal)
        try writeDataAtomically(envelope, destination: journalURL, injectFaults: true)
        let verified = try decodeEnvelope(Data(contentsOf: journalURL))
        guard try digestPayload(verified) == digestPayload(journal) else {
            throw InstallationStateFailure.writeFailed("postWriteMismatch")
        }
        return verified
    }

    private func writeDataAtomically(
        _ data: Data,
        destination: URL,
        injectFaults: Bool
    ) throws {
        let temporary = rootURL.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InstallationStateFailure.writeFailed("temporaryOpen") }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    guard count > 0 else { throw InstallationStateFailure.writeFailed("temporaryWrite") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw InstallationStateFailure.writeFailed("temporarySync") }
            guard close(descriptor) == 0 else { throw InstallationStateFailure.writeFailed("temporaryClose") }
            shouldClose = false
            if injectFaults { try faultInjector(.afterTemporaryFileSyncBeforeRename) }
            guard rename(temporary.path, destination.path) == 0 else {
                throw InstallationStateFailure.writeFailed("rename")
            }
            if injectFaults { try faultInjector(.afterRenameBeforeDirectorySync) }
            let directoryDescriptor = open(rootURL.path, O_RDONLY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else { throw InstallationStateFailure.writeFailed("directoryOpen") }
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw InstallationStateFailure.writeFailed("directorySync")
            }
            if injectFaults { try faultInjector(.beforePostWriteVerification) }
        } catch {
            throw error
        }
    }

    private func encodeEnvelope(_ journal: InstallationJournal) throws -> Data {
        let envelope = InstallationJournalEnvelope(
            schemaVersion: InstallationJournal.currentSchemaVersion,
            digest: try digestPayload(journal),
            payload: journal
        )
        return try encoder().encode(envelope)
    }

    private func decodeEnvelope(_ data: Data) throws -> InstallationJournal {
        let envelope = try decoder().decode(InstallationJournalEnvelope.self, from: data)
        guard envelope.schemaVersion <= InstallationJournal.currentSchemaVersion,
              envelope.digest == (try digestPayload(envelope.payload)) else {
            throw InstallationStateFailure.corruptJournal
        }
        return envelope.payload
    }

    private func digestPayload(_ journal: InstallationJournal) throws -> String {
        let data = try encoder().encode(journal)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    private func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        value.dateEncodingStrategy = .millisecondsSince1970
        return value
    }

    private func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .millisecondsSince1970
        return value
    }
}
