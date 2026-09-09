import Foundation

public enum XcodeBootstrapState: String, Codable, Equatable, Sendable {
    case checking = "XCODE_CHECKING"
    case notFound = "XCODE_NOT_FOUND"
    case downloadAuthenticationRequired = "XCODE_DOWNLOAD_AUTH_REQUIRED"
    case downloading = "XCODE_DOWNLOADING"
    case verifyingDownload = "XCODE_VERIFYING_DOWNLOAD"
    case installAuthorizationRequired = "XCODE_INSTALL_AUTH_REQUIRED"
    case installing = "XCODE_INSTALLING"
    case licenseRequired = "XCODE_LICENSE_REQUIRED"
    case initializing = "XCODE_INITIALIZING"
    case verifying = "XCODE_VERIFYING"
    case ready = "XCODE_READY"
    case failed = "XCODE_FAILED"
}

public struct XcodeRelease: Codable, Equatable, Sendable {
    public let version: XcodeVersion
    public let buildVersion: String
    public let minimumMacOSVersion: XcodeVersion
    public let archiveFileName: String
    public let approximateDownloadBytes: Int64
    public let requiredFreeSpaceBytes: Int64
    public let stable: Bool

    public init(
        version: XcodeVersion,
        buildVersion: String,
        minimumMacOSVersion: XcodeVersion,
        archiveFileName: String,
        approximateDownloadBytes: Int64,
        requiredFreeSpaceBytes: Int64,
        stable: Bool
    ) {
        self.version = version
        self.buildVersion = buildVersion
        self.minimumMacOSVersion = minimumMacOSVersion
        self.archiveFileName = archiveFileName
        self.approximateDownloadBytes = approximateDownloadBytes
        self.requiredFreeSpaceBytes = requiredFreeSpaceBytes
        self.stable = stable
    }

    public static let consumerPinned = XcodeRelease(
        version: XcodeVersion("26.6"),
        buildVersion: "17F113",
        minimumMacOSVersion: XcodeVersion("26.2"),
        archiveFileName: "Xcode_26.6.xip",
        approximateDownloadBytes: 12 * 1_024 * 1_024 * 1_024,
        requiredFreeSpaceBytes: 45 * 1_024 * 1_024 * 1_024,
        stable: true
    )
}

/// An authenticated request returned by a dedicated Apple-download login
/// adapter. This is deliberately neither Codable nor persistable.
public final class EphemeralXcodeDownloadAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var requestStorage: URLRequest?

    public init(request: URLRequest) throws {
        try OfficialAppleDownloadPolicy.validate(request.url)
        requestStorage = request
    }

    public func request() throws -> URLRequest {
        lock.lock()
        defer { lock.unlock() }
        guard let requestStorage else { throw XcodeBootstrapError.authorizationExpired }
        return requestStorage
    }

    public func clear() {
        lock.lock()
        requestStorage = nil
        lock.unlock()
    }

    deinit { clear() }
}

public enum OfficialAppleDownloadPolicy {
    public static let allowedHosts: Set<String> = [
        "developer.apple.com",
        "download.developer.apple.com",
        "adcdownload.apple.com"
    ]

    public static func validate(_ url: URL?) throws {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            throw XcodeBootstrapError.untrustedDownloadURL
        }
    }
}

public enum XcodeBootstrapError: Error, Equatable, Sendable {
    case authenticationRequired
    case authorizationExpired
    case untrustedDownloadURL
    case invalidHTTPStatus(Int)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case downloadIncomplete
    case archiveExpansionFailed
    case xcodeApplicationMissing
    case xcodeIdentityInvalid
    case installDestinationExists
    case installAuthorizationCancelled
    case installationFailed
    case licenseAcceptanceRequired
    case initializationAuthorizationCancelled
    case initializationFailed
    case capabilityVerificationFailed
}

public struct XcodeDownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public protocol XcodeArchiveDownloading: Sendable {
    func download(
        authorization: EphemeralXcodeDownloadAuthorization,
        destinationURL: URL,
        requiredFreeSpace: Int64,
        progress: @escaping @Sendable (XcodeDownloadProgress) -> Void
    ) async throws -> URL
}

/// HTTPS-only streaming downloader. A `.partial` file is the only durable
/// resume checkpoint; request headers, cookies, passwords, 2FA, and URLSession
/// resume blobs are never persisted.
public struct AppleXcodeArchiveDownloader: XcodeArchiveDownloading, @unchecked Sendable {
    public typealias CapacityProvider = @Sendable (URL) throws -> Int64

    private let configuration: URLSessionConfiguration
    private let capacityProvider: CapacityProvider

    public init() {
        configuration = .ephemeral
        capacityProvider = { try Self.availableCapacity(at: $0) }
    }

    public init(
        configuration: URLSessionConfiguration,
        capacityProvider: @escaping CapacityProvider
    ) {
        self.configuration = configuration
        self.capacityProvider = capacityProvider
    }

    public func download(
        authorization: EphemeralXcodeDownloadAuthorization,
        destinationURL: URL,
        requiredFreeSpace: Int64,
        progress: @escaping @Sendable (XcodeDownloadProgress) -> Void
    ) async throws -> URL {
        let available = try capacityProvider(destinationURL.deletingLastPathComponent())
        guard available >= requiredFreeSpace else {
            throw XcodeBootstrapError.insufficientDiskSpace(required: requiredFreeSpace, available: available)
        }
        let operation = try StreamingAppleDownload(
            request: authorization.request(),
            destinationURL: destinationURL,
            configuration: configuration,
            progress: progress
        )
        return try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }

    private static func availableCapacity(at directoryURL: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

private final class StreamingAppleDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let request: URLRequest
    private let destinationURL: URL
    private let partialURL: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (XcodeDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var existingBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var terminalError: Error?
    private var completed = false
    private var cancelRequested = false

    init(
        request: URLRequest,
        destinationURL: URL,
        configuration: URLSessionConfiguration,
        progress: @escaping @Sendable (XcodeDownloadProgress) -> Void
    ) throws {
        try OfficialAppleDownloadPolicy.validate(request.url)
        self.request = request
        self.destinationURL = destinationURL
        partialURL = destinationURL.appendingPathExtension("partial")
        self.configuration = configuration
        self.progress = progress
        super.init()
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            do {
                try prepareAndStart()
            } catch {
                finish(.failure(error))
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func prepareAndStart() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: partialURL.path) {
            manager.createFile(atPath: partialURL.path, contents: nil)
        }
        existingBytes = Int64((try? manager.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var resumedRequest = request
        resumedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        resumedRequest.timeoutInterval = 120
        if existingBytes > 0 {
            resumedRequest.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: resumedRequest)
        lock.lock()
        self.session = session
        self.task = task
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try OfficialAppleDownloadPolicy.validate(request.url)
            completionHandler(request)
        } catch {
            terminalError = error
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            terminalError = XcodeBootstrapError.downloadIncomplete
            completionHandler(.cancel)
            return
        }
        do {
            try OfficialAppleDownloadPolicy.validate(response.url)
            guard response.statusCode == 200 || response.statusCode == 206 else {
                terminalError = response.statusCode == 401 || response.statusCode == 403
                    ? XcodeBootstrapError.authenticationRequired
                    : XcodeBootstrapError.invalidHTTPStatus(response.statusCode)
                completionHandler(.cancel)
                return
            }
            if response.statusCode == 206,
               response.value(forHTTPHeaderField: "Content-Range")?
               .range(of: "bytes \(existingBytes)-", options: [.anchored, .caseInsensitive]) == nil {
                try Data().write(to: partialURL, options: .atomic)
                terminalError = XcodeBootstrapError.downloadIncomplete
                completionHandler(.cancel)
                return
            }
            if response.statusCode == 200, existingBytes > 0 {
                existingBytes = 0
                try Data().write(to: partialURL, options: .atomic)
            }
            handle = try FileHandle(forWritingTo: partialURL)
            try handle?.seekToEnd()
            let contentLength = response.expectedContentLength
            totalBytes = contentLength > 0 ? existingBytes + contentLength : nil
            progress(.init(completedBytes: existingBytes, totalBytes: totalBytes))
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            progress(.init(completedBytes: existingBytes + receivedBytes, totalBytes: totalBytes))
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let terminalError {
            finish(.failure(terminalError))
        } else if let error {
            finish(.failure(error))
        } else {
            do {
                if let totalBytes, existingBytes + receivedBytes != totalBytes {
                    throw XcodeBootstrapError.downloadIncomplete
                }
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: partialURL, to: destinationURL)
                finish(.success(destinationURL))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

public struct XcodeArtifactVerifier: Sendable {
    private let runner: ProcessRunner
    private let policy: XcodeCompatibilityPolicy
    private let release: XcodeRelease

    public init(
        runner: ProcessRunner = ProcessRunner(),
        policy: XcodeCompatibilityPolicy = .consumer,
        release: XcodeRelease = .consumerPinned
    ) {
        self.runner = runner
        self.policy = policy
        self.release = release
    }

    public func verifyExtractedApplication(_ applicationURL: URL) async throws {
        guard let info = XcodeApplicationDiscovery.bundleInfo(applicationURL),
              info["CFBundleIdentifier"] as? String == policy.expectedBundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              XcodeVersion(version) == policy.pinnedStableVersion,
              XcodeApplicationDiscovery.buildVersion(applicationURL, bundleInfo: info) == release.buildVersion else {
            throw XcodeBootstrapError.xcodeIdentityInvalid
        }
        let environment = RuntimeProvisioning.baseDeterministicEnvironment()
        let verify = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        let identity = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", applicationURL.path],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        let gatekeeper = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=2", applicationURL.path],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        guard verify.exitCode == 0,
              gatekeeper.exitCode == 0,
              identity.combinedOutput.contains("TeamIdentifier=\(policy.appleTeamIdentifier)") else {
            throw XcodeBootstrapError.xcodeIdentityInvalid
        }
    }
}

public struct XcodeArchiveExpander: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) { self.runner = runner }

    public func expand(archiveURL: URL, stagingDirectory: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: stagingDirectory.path) {
            try FileManager.default.removeItem(at: stagingDirectory)
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xip"),
            arguments: ["--expand", archiveURL.path],
            workingDirectory: stagingDirectory,
            environment: RuntimeProvisioning.baseDeterministicEnvironment()
        )
        guard result.exitCode == 0 else { throw XcodeBootstrapError.archiveExpansionFailed }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "app" }
        guard candidates.count == 1 else { throw XcodeBootstrapError.xcodeApplicationMissing }
        return candidates[0]
    }
}

public struct XcodePrivilegedInstaller: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) { self.runner = runner }

    /// Uses macOS's authorization dialog. IOSSim never receives or logs the
    /// administrator password; argv contains paths only.
    public func install(applicationURL: URL, destinationURL: URL) async throws -> URL {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw XcodeBootstrapError.installDestinationExists
        }
        let script = """
        on run argv
          set sourcePath to item 1 of argv
          set destinationPath to item 2 of argv
          do shell script \"/usr/bin/ditto \" & quoted form of sourcePath & \" \" & quoted form of destinationPath with administrator privileges
        end run
        """
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, applicationURL.path, destinationURL.path],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: RuntimeProvisioning.baseDeterministicEnvironment()
        )
        guard result.exitCode == 0 else {
            let cancelled = result.combinedOutput.localizedCaseInsensitiveContains("canceled")
                || result.combinedOutput.localizedCaseInsensitiveContains("cancelled")
                || result.exitCode == 128
            throw cancelled
                ? XcodeBootstrapError.installAuthorizationCancelled
                : XcodeBootstrapError.installationFailed
        }
        return destinationURL
    }
}

public struct XcodeCommandLineInitializer: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) { self.runner = runner }

    public func initialize(applicationURL: URL, userAcceptedLicense: Bool) async throws {
        guard userAcceptedLicense else { throw XcodeBootstrapError.licenseAcceptanceRequired }
        let developerDirectory = applicationURL.appendingPathComponent("Contents/Developer", isDirectory: true)
        let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        let script = """
        on run argv
          set xcodebuildPath to item 1 of argv
          do shell script quoted form of xcodebuildPath & " -runFirstLaunch" with administrator privileges
        end run
        """
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, xcodebuild.path],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: XcodeApplicationDiscovery.environment(developerDirectory: developerDirectory)
        )
        guard result.exitCode == 0 else {
            let cancelled = result.combinedOutput.localizedCaseInsensitiveContains("canceled")
                || result.combinedOutput.localizedCaseInsensitiveContains("cancelled")
                || result.exitCode == 128
            throw cancelled
                ? XcodeBootstrapError.initializationAuthorizationCancelled
                : XcodeBootstrapError.initializationFailed
        }
    }

    public func verify(applicationURL: URL) async throws -> XcodeDetectionReport {
        let detector = XcodePrerequisiteDetector(candidatePaths: { [applicationURL] }, runner: runner)
        let report = await detector.detect()
        guard report.isReady else { throw XcodeBootstrapError.capabilityVerificationFailed }
        return report
    }
}

public struct XcodeBootstrapCheckpoint: Codable, Equatable, Sendable {
    public let release: XcodeRelease
    public var archiveDownloaded: Bool
    public var applicationVerified: Bool
    public var installedApplicationPath: String?
    public var initialized: Bool
    public var devicectlVerified: Bool

    public init(release: XcodeRelease) {
        self.release = release
        archiveDownloaded = false
        applicationVerified = false
        installedApplicationPath = nil
        initialized = false
        devicectlVerified = false
    }
}

public final class XcodeBootstrapCheckpointStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IOSSim/XcodeBootstrap", isDirectory: true)
    }

    public var archiveURL: URL { rootURL.appendingPathComponent(XcodeRelease.consumerPinned.archiveFileName) }
    public var extractionURL: URL { rootURL.appendingPathComponent("Extracting", isDirectory: true) }
    public var checkpointURL: URL { rootURL.appendingPathComponent("checkpoint.json") }

    public func load() throws -> XcodeBootstrapCheckpoint? {
        guard fileManager.fileExists(atPath: checkpointURL.path) else { return nil }
        return try JSONDecoder().decode(XcodeBootstrapCheckpoint.self, from: Data(contentsOf: checkpointURL))
    }

    public func save(_ checkpoint: XcodeBootstrapCheckpoint) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: checkpointURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
    }

    public func discardPartialExtraction() throws {
        if fileManager.fileExists(atPath: extractionURL.path) {
            try fileManager.removeItem(at: extractionURL)
        }
    }
}
