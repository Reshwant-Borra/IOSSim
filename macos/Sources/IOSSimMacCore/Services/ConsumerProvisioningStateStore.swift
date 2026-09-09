import Foundation

public actor ConsumerProvisioningStateStore {
    public static let manifestFileName = "provisioning-state.json"
    public static let logFileName = "provisioning-events.jsonl"

    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directoryURL = support.appendingPathComponent("IOSSim", isDirectory: true)
        }
    }

    public var manifestURL: URL {
        directoryURL.appendingPathComponent(Self.manifestFileName)
    }

    public var logURL: URL {
        directoryURL.appendingPathComponent(Self.logFileName)
    }

    public func loadManifest() throws -> ConsumerProvisioningManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let manifest = try JSONDecoder.iossim.decode(ConsumerProvisioningManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == ConsumerProvisioningManifest.currentSchemaVersion else {
                throw ConsumerProvisioningFailure(
                    code: .manifestCorrupt,
                    stage: .checkingProfileExpiration,
                    userMessage: "IOSSim setup information needs repair.",
                    remediation: "Choose Repair to rebuild the local setup record without removing iPhone data.",
                    developerDetail: "Unsupported manifest schema \(manifest.schemaVersion)."
                )
            }
            return manifest
        } catch let failure as ConsumerProvisioningFailure {
            throw failure
        } catch {
            throw ConsumerProvisioningFailure(
                code: .manifestCorrupt,
                stage: .checkingProfileExpiration,
                userMessage: "IOSSim setup information needs repair.",
                remediation: "Choose Repair to inspect the current installation and rebuild the local setup record.",
                developerDetail: String(describing: error)
            )
        }
    }

    public func saveManifest(_ manifest: ConsumerProvisioningManifest) throws {
        try ensureDirectory()
        let data = try JSONEncoder.iossim.encode(manifest)
        let temporaryURL = directoryURL.appendingPathComponent(".\(Self.manifestFileName).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: [.atomic])
        if fileManager.fileExists(atPath: manifestURL.path) {
            _ = try fileManager.replaceItemAt(manifestURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: manifestURL)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    public func markRuntimeSetupReady(checkedAt: Date = Date()) throws -> ConsumerProvisioningManifest {
        guard let manifest = try loadManifest() else {
            throw ConsumerProvisioningFailure(
                code: .runnerMappingMissing,
                stage: .verifyingRuntimeReadiness,
                userMessage: "IOSSim installation information is missing.",
                remediation: "Choose Repair before completing iPhone setup.",
                developerDetail: "Runtime setup cannot be confirmed without a provisioning manifest."
            )
        }
        let updated = manifest.updatingRuntimeSetupStatus(.ready, checkedAt: checkedAt)
        try saveManifest(updated)
        return updated
    }

    public func append(_ event: ProvisioningLogEvent) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)
        if fileManager.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: logURL, options: [.atomic])
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    public func loadEvents(limit: Int = 500) -> [ProvisioningLogEvent] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return Self.decodeEvents(data).suffix(max(0, limit)).map { $0 }
    }

    static func decodeEvents(_ data: Data) -> [ProvisioningLogEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var objects: [Data] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(Data(text[objectStart...index].utf8))
                    start = nil
                }
            }
        }
        return objects.compactMap {
            try? JSONDecoder.iossim.decode(ProvisioningLogEvent.self, from: $0)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }
}

public actor ConsumerRefreshCoordinator {
    private var running = false

    public init() {}

    public func begin() throws {
        guard !running else {
            throw ConsumerProvisioningFailure(
                code: .operationInProgress,
                stage: .checkingProfileExpiration,
                userMessage: "IOSSim is already being refreshed.",
                remediation: "Wait for the current refresh to finish.",
                developerDetail: "Concurrent provisioning operation rejected."
            )
        }
        running = true
    }

    public func end() {
        running = false
    }

    public func isRunning() -> Bool { running }
}

extension JSONEncoder {
    fileprivate static var iossim: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var iossim: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
