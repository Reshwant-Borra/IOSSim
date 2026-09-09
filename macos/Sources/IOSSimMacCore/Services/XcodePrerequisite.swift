import Foundation

public enum XcodePrerequisiteState: String, Codable, Equatable, Sendable {
    case notFound = "XCODE_NOT_FOUND"
    case commandLineToolsOnly = "XCODE_COMMAND_LINE_TOOLS_ONLY"
    case incompatible = "XCODE_INCOMPATIBLE"
    case damaged = "XCODE_DAMAGED"
    case notInitialized = "XCODE_NOT_INITIALIZED"
    case devicectlUnavailable = "XCODE_DEVICECTL_UNAVAILABLE"
    case readyUsingAlternative = "XCODE_READY_USING_ALTERNATIVE"
    case ready = "XCODE_READY"
}

public struct XcodeVersion: Codable, Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(_ rawValue: String) {
        let numericVersion = rawValue.split { character in
            !character.isNumber && character != "."
        }.first.map(String.init) ?? "0"
        let parsed = numericVersion.split(separator: ".").map { component -> Int in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
        components = parsed.isEmpty ? [0] : parsed
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct XcodeCompatibilityPolicy: Equatable, Sendable {
    public static let consumer = XcodeCompatibilityPolicy(
        minimumVersion: XcodeVersion("15.0"),
        pinnedStableVersion: XcodeVersion("26.6"),
        expectedBundleIdentifier: "com.apple.dt.Xcode",
        appleTeamIdentifier: "59GAB85EFG"
    )

    public let minimumVersion: XcodeVersion
    public let pinnedStableVersion: XcodeVersion
    public let expectedBundleIdentifier: String
    public let appleTeamIdentifier: String

    /// Conservative major-version map for the device OS generations each
    /// stable Xcode line is expected to support. Unknown lines fail closed.
    public static let maximumDeviceOSMajorByXcodeMajor = [15: 17, 16: 18, 26: 26]

    public init(
        minimumVersion: XcodeVersion,
        pinnedStableVersion: XcodeVersion,
        expectedBundleIdentifier: String,
        appleTeamIdentifier: String
    ) {
        self.minimumVersion = minimumVersion
        self.pinnedStableVersion = pinnedStableVersion
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.appleTeamIdentifier = appleTeamIdentifier
    }

    public func supports(deviceOSVersion: XcodeVersion, withXcodeVersion xcodeVersion: XcodeVersion) -> Bool {
        guard let xcodeMajor = xcodeVersion.components.first,
              let deviceMajor = deviceOSVersion.components.first,
              let maximumDeviceMajor = Self.maximumDeviceOSMajorByXcodeMajor[xcodeMajor] else {
            return false
        }
        return deviceMajor <= maximumDeviceMajor
    }
}

public struct XcodeInstallation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { applicationURL.path }
    public let applicationURL: URL
    public let developerDirectoryURL: URL
    public let version: XcodeVersion
    public let buildVersion: String
    public let minimumMacOSVersion: XcodeVersion?
    public let isPrerelease: Bool
    public let state: XcodePrerequisiteState
    public let detail: String

    public init(
        applicationURL: URL,
        developerDirectoryURL: URL,
        version: XcodeVersion,
        buildVersion: String,
        minimumMacOSVersion: XcodeVersion?,
        isPrerelease: Bool,
        state: XcodePrerequisiteState,
        detail: String
    ) {
        self.applicationURL = applicationURL
        self.developerDirectoryURL = developerDirectoryURL
        self.version = version
        self.buildVersion = buildVersion
        self.minimumMacOSVersion = minimumMacOSVersion
        self.isPrerelease = isPrerelease
        self.state = state
        self.detail = detail
    }

    public var isReady: Bool {
        state == .ready || state == .readyUsingAlternative
    }
}

public struct XcodeDetectionReport: Codable, Equatable, Sendable {
    public let state: XcodePrerequisiteState
    public let selectedInstallation: XcodeInstallation?
    public let installations: [XcodeInstallation]
    public let systemDeveloperDirectory: String?
    public let multipleInstallations: Bool
    public let detail: String

    public init(
        state: XcodePrerequisiteState,
        selectedInstallation: XcodeInstallation?,
        installations: [XcodeInstallation],
        systemDeveloperDirectory: String?,
        multipleInstallations: Bool,
        detail: String
    ) {
        self.state = state
        self.selectedInstallation = selectedInstallation
        self.installations = installations
        self.systemDeveloperDirectory = systemDeveloperDirectory
        self.multipleInstallations = multipleInstallations
        self.detail = detail
    }

    public var isReady: Bool { selectedInstallation?.isReady == true }
}

public struct XcodePrerequisiteDetector {
    public typealias CandidatePaths = () -> [URL]
    public typealias BundleInfo = (URL) -> [String: Any]?
    public typealias PathCheck = (String) -> Bool
    public typealias SystemDeveloperDirectory = () async -> String?
    public typealias VerifiedSelectionHandler = @Sendable (URL) -> Void

    private let policy: XcodeCompatibilityPolicy
    private let candidatePaths: CandidatePaths
    private let bundleInfo: BundleInfo
    private let directoryExists: PathCheck
    private let executableExists: PathCheck
    private let systemDeveloperDirectory: SystemDeveloperDirectory
    private let runner: ProcessRunner
    private let currentMacOSVersion: XcodeVersion
    private let requiredDeviceOSVersion: XcodeVersion?
    private let verifiedSelectionHandler: VerifiedSelectionHandler

    public init(
        policy: XcodeCompatibilityPolicy = .consumer,
        candidatePaths: @escaping CandidatePaths = XcodeApplicationDiscovery.candidateApplicationURLs,
        bundleInfo: @escaping BundleInfo = XcodeApplicationDiscovery.bundleInfo,
        directoryExists: @escaping PathCheck = { FileManager.default.fileExists(atPath: $0) },
        executableExists: @escaping PathCheck = { FileManager.default.isExecutableFile(atPath: $0) },
        systemDeveloperDirectory: @escaping SystemDeveloperDirectory = XcodeApplicationDiscovery.systemDeveloperDirectory,
        runner: ProcessRunner = ProcessRunner(),
        currentMacOSVersion: XcodeVersion = XcodeVersion(ProcessInfo.processInfo.operatingSystemVersionString),
        requiredDeviceOSVersion: XcodeVersion? = nil,
        verifiedSelectionHandler: @escaping VerifiedSelectionHandler = {
            XcodeApplicationDiscovery.recordVerifiedDeveloperDirectory($0)
        }
    ) {
        self.policy = policy
        self.candidatePaths = candidatePaths
        self.bundleInfo = bundleInfo
        self.directoryExists = directoryExists
        self.executableExists = executableExists
        self.systemDeveloperDirectory = systemDeveloperDirectory
        self.runner = runner
        self.currentMacOSVersion = currentMacOSVersion
        self.requiredDeviceOSVersion = requiredDeviceOSVersion
        self.verifiedSelectionHandler = verifiedSelectionHandler
    }

    public func detect() async -> XcodeDetectionReport {
        let systemDirectory = await systemDeveloperDirectory()
        let candidates = candidatePaths()
        if candidates.isEmpty {
            let cltOnly = systemDirectory?.contains("CommandLineTools") == true
            return XcodeDetectionReport(
                state: cltOnly ? .commandLineToolsOnly : .notFound,
                selectedInstallation: nil,
                installations: [],
                systemDeveloperDirectory: systemDirectory,
                multipleInstallations: false,
                detail: cltOnly ? "Only Apple Command Line Tools are selected." : "No full Xcode installation was found."
            )
        }

        var installations: [XcodeInstallation] = []
        for applicationURL in candidates {
            installations.append(await inspect(applicationURL))
        }
        installations.sort {
            if $0.isReady != $1.isReady { return $0.isReady && !$1.isReady }
            if $0.isPrerelease != $1.isPrerelease { return !$0.isPrerelease && $1.isPrerelease }
            if $0.version != $1.version { return $0.version > $1.version }
            return $0.applicationURL.path < $1.applicationURL.path
        }

        guard var selected = installations.first(where: \.isReady) else {
            let state = installations.first?.state ?? .damaged
            return XcodeDetectionReport(
                state: state,
                selectedInstallation: nil,
                installations: installations,
                systemDeveloperDirectory: systemDirectory,
                multipleInstallations: installations.count > 1,
                detail: installations.first?.detail ?? "No usable Xcode installation was found."
            )
        }
        let usesAlternative = normalized(systemDirectory) != normalized(selected.developerDirectoryURL.path)
        if usesAlternative {
            selected = XcodeInstallation(
                applicationURL: selected.applicationURL,
                developerDirectoryURL: selected.developerDirectoryURL,
                version: selected.version,
                buildVersion: selected.buildVersion,
                minimumMacOSVersion: selected.minimumMacOSVersion,
                isPrerelease: selected.isPrerelease,
                state: .readyUsingAlternative,
                detail: "IOSSim will use this compatible Xcode without changing the global developer directory."
            )
            if let index = installations.firstIndex(where: { $0.id == selected.id }) {
                installations[index] = selected
            }
        }
        verifiedSelectionHandler(selected.developerDirectoryURL)
        return XcodeDetectionReport(
            state: selected.state,
            selectedInstallation: selected,
            installations: installations,
            systemDeveloperDirectory: systemDirectory,
            multipleInstallations: installations.count > 1,
            detail: selected.detail
        )
    }

    private func inspect(_ applicationURL: URL) async -> XcodeInstallation {
        let developerDirectory = applicationURL.appendingPathComponent("Contents/Developer", isDirectory: true)
        let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        let info = bundleInfo(applicationURL) ?? [:]
        let versionText = info["CFBundleShortVersionString"] as? String ?? "0"
        let version = XcodeVersion(versionText)
        let build = XcodeApplicationDiscovery.buildVersion(applicationURL, bundleInfo: info) ?? "unknown"
        let minimumMac = (info["LSMinimumSystemVersion"] as? String).map(XcodeVersion.init)
        let prerelease = applicationURL.lastPathComponent.localizedCaseInsensitiveContains("beta")
            || applicationURL.lastPathComponent.localizedCaseInsensitiveContains("rc")
        let base = { (state: XcodePrerequisiteState, detail: String) in
            XcodeInstallation(
                applicationURL: applicationURL,
                developerDirectoryURL: developerDirectory,
                version: version,
                buildVersion: build,
                minimumMacOSVersion: minimumMac,
                isPrerelease: prerelease,
                state: state,
                detail: detail
            )
        }
        guard info["CFBundleIdentifier"] as? String == policy.expectedBundleIdentifier,
              directoryExists(developerDirectory.path), executableExists(xcodebuild.path) else {
            return base(.damaged, "The Xcode application is incomplete or has an unexpected bundle identity.")
        }
        guard version >= policy.minimumVersion,
              minimumMac.map({ currentMacOSVersion >= $0 }) ?? true else {
            return base(.incompatible, "Xcode \(versionText) is not compatible with IOSSim or this macOS version.")
        }
        if let requiredDeviceOSVersion,
           !policy.supports(deviceOSVersion: requiredDeviceOSVersion, withXcodeVersion: version) {
            return base(.incompatible, "Xcode \(versionText) does not satisfy the selected iPhone OS requirement.")
        }

        let environment = XcodeApplicationDiscovery.environment(developerDirectory: developerDirectory)
        let firstLaunch = try? await runner.run(
            executableURL: xcodebuild,
            arguments: ["-checkFirstLaunchStatus"],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        guard firstLaunch?.exitCode == 0 else {
            return base(.notInitialized, "Xcode is installed but Apple command-line first-launch tasks remain.")
        }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard executableExists(xcrun.path) else {
            return base(.devicectlUnavailable, "/usr/bin/xcrun is unavailable.")
        }
        let find = try? await runner.run(
            executableURL: xcrun,
            arguments: ["--find", "devicectl"],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        let versionProbe = try? await runner.run(
            executableURL: xcrun,
            arguments: ["devicectl", "--version"],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-devicectl-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        let coreDeviceProbe = try? await runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl", "list", "devices", "--timeout", "5",
                "--json-output", probeRoot.appendingPathComponent("devices.json").path,
                "--quiet"
            ],
            workingDirectory: applicationURL.deletingLastPathComponent(),
            environment: environment
        )
        guard find?.exitCode == 0, versionProbe?.exitCode == 0, coreDeviceProbe?.exitCode == 0 else {
            return base(.devicectlUnavailable, "Xcode exists, but its devicectl capability is unavailable.")
        }
        return base(.ready, "Xcode \(versionText) (\(build)) provides an initialized devicectl toolchain.")
    }

    private func normalized(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

public enum XcodeApplicationDiscovery {
    public static func candidateApplicationURLs() -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(userApplications)
        }
        var candidates: [URL] = []
        for directory in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates += contents.filter {
                guard $0.pathExtension == "app" else { return false }
                let isNamedXcode = $0.deletingPathExtension().lastPathComponent
                    .range(of: "Xcode", options: [.anchored, .caseInsensitive]) != nil
                let hasXcodeIdentity = bundleInfo($0)?["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode"
                return isNamedXcode || hasXcodeIdentity
            }
        }
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           let application = applicationURL(fromDeveloperDirectory: override) {
            candidates.append(application)
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func preferredDeveloperDirectory() -> URL? {
        let policy = XcodeCompatibilityPolicy.consumer
        var candidates = candidateApplicationURLs()
        if let verified = verifiedDeveloperDirectory(),
           let application = applicationURL(fromDeveloperDirectory: verified.path) {
            candidates.insert(application, at: 0)
        }
        let installations = candidates.compactMap { application -> (URL, XcodeVersion, Bool, Bool)? in
            guard let info = bundleInfo(application),
                  info["CFBundleIdentifier"] as? String == policy.expectedBundleIdentifier,
                  let rawVersion = info["CFBundleShortVersionString"] as? String else { return nil }
            let developerDirectory = application.appendingPathComponent("Contents/Developer", isDirectory: true)
            let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
            guard FileManager.default.fileExists(atPath: developerDirectory.path),
                  FileManager.default.isExecutableFile(atPath: xcodebuild.path) else { return nil }
            let prerelease = application.lastPathComponent.localizedCaseInsensitiveContains("beta")
                || application.lastPathComponent.localizedCaseInsensitiveContains("rc")
            let wasVerified = developerDirectory.standardizedFileURL == verifiedDeveloperDirectory()?.standardizedFileURL
            return (developerDirectory, XcodeVersion(rawVersion), prerelease, wasVerified)
        }.filter { $0.1 >= policy.minimumVersion }
            .sorted {
                if $0.3 != $1.3 { return $0.3 && !$1.3 }
                if $0.2 != $1.2 { return !$0.2 && $1.2 }
                return $0.1 > $1.1
            }
        return installations.first?.0
    }

    /// Persists only the path of a detector-qualified toolchain so later
    /// provisioner subprocesses keep using that exact Xcode per process.
    public static func recordVerifiedDeveloperDirectory(_ developerDirectory: URL) {
        let fileURL = verifiedSelectionURL()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(developerDirectory.standardizedFileURL.path.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Qualification remains valid for the current process even if the
            // non-sensitive convenience checkpoint cannot be persisted.
        }
    }

    public static func verifiedDeveloperDirectory() -> URL? {
        let fileURL = verifiedSelectionURL()
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func verifiedSelectionURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IOSSim/XcodeBootstrap", isDirectory: true)
            .appendingPathComponent("verified-developer-directory")
    }

    public static func bundleInfo(_ applicationURL: URL) -> [String: Any]? {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return root as? [String: Any]
    }

    public static func buildVersion(_ applicationURL: URL, bundleInfo: [String: Any]? = nil) -> String? {
        let versionURL = applicationURL.appendingPathComponent("Contents/version.plist")
        if let data = try? Data(contentsOf: versionURL),
           let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let version = root as? [String: Any],
           let productBuild = version["ProductBuildVersion"] as? String {
            return productBuild
        }
        return bundleInfo?["DTXcodeBuild"] as? String
    }

    public static func systemDeveloperDirectory() async -> String? {
        let result = try? await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            workingDirectory: URL(fileURLWithPath: "/"),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        )
        guard result?.exitCode == 0 else { return nil }
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func applicationURL(fromDeveloperDirectory path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "Developer", url.deletingLastPathComponent().lastPathComponent == "Contents" else {
            return nil
        }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    public static func environment(developerDirectory: URL) -> [String: String] {
        var environment = RuntimeProvisioning.baseDeterministicEnvironment()
        environment["DEVELOPER_DIR"] = developerDirectory.path
        return environment
    }
}
