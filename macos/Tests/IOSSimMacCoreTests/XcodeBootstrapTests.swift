import XCTest
@testable import IOSSimMacCore

final class XcodeBootstrapTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStop = nil
        super.tearDown()
    }

    func testOfficialDownloadPolicyRejectsHTTPAndNonAppleHosts() throws {
        XCTAssertThrowsError(try OfficialAppleDownloadPolicy.validate(URL(string: "http://developer.apple.com/file.xip")))
        XCTAssertThrowsError(try OfficialAppleDownloadPolicy.validate(URL(string: "https://example.com/Xcode.xip")))
        XCTAssertNoThrow(try OfficialAppleDownloadPolicy.validate(URL(string: "https://developer.apple.com/services-account/download")))
    }

    func testDownloadAuthorizationCanBeExplicitlyCleared() throws {
        let authorization = try EphemeralXcodeDownloadAuthorization(
            request: URLRequest(url: URL(string: "https://developer.apple.com/services-account/download")!)
        )
        XCTAssertNoThrow(try authorization.request())
        authorization.clear()
        XCTAssertThrowsError(try authorization.request()) { error in
            XCTAssertEqual(error as? XcodeBootstrapError, .authorizationExpired)
        }
    }

    func testCheckpointContainsNoCredentialFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-xcode-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = XcodeBootstrapCheckpointStore(rootURL: root)
        var checkpoint = XcodeBootstrapCheckpoint(release: .consumerPinned)
        checkpoint.archiveDownloaded = true
        try store.save(checkpoint)

        XCTAssertEqual(try store.load(), checkpoint)
        let text = try String(contentsOf: store.checkpointURL, encoding: .utf8).lowercased()
        for forbidden in ["password", "2fa", "verificationcode", "cookie", "authorization"] {
            XCTAssertFalse(text.contains(forbidden), "checkpoint unexpectedly contained \(forbidden)")
        }
    }

    func testInitializerRequiresExplicitLicenseAcceptanceBeforeLaunchingXcodebuild() async {
        let calls = LockedCommandRecorder()
        let initializer = XcodeCommandLineInitializer(runner: ProcessRunner { executable, arguments, _, _, _ in
            calls.append(executable.path, arguments)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        })

        do {
            try await initializer.initialize(
                applicationURL: URL(fileURLWithPath: "/Applications/IOSSim-Xcode.app"),
                userAcceptedLicense: false
            )
            XCTFail("expected license gate")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .licenseAcceptanceRequired)
        }
        XCTAssertTrue(calls.commands.isEmpty)
    }

    func testInitializerUsesMacOSAuthorizationWithoutPasswordArguments() async throws {
        let calls = LockedCommandRecorder()
        let initializer = XcodeCommandLineInitializer(runner: ProcessRunner { executable, arguments, _, _, _ in
            calls.append(executable.path, arguments)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        })

        try await initializer.initialize(
            applicationURL: URL(fileURLWithPath: "/Applications/IOSSim-Xcode.app"),
            userAcceptedLicense: true
        )

        XCTAssertEqual(calls.commands.count, 1)
        XCTAssertEqual(calls.commands[0].executable, "/usr/bin/osascript")
        XCTAssertTrue(calls.commands[0].arguments.joined(separator: " ").contains("-runFirstLaunch"))
        XCTAssertFalse(calls.commands[0].arguments.joined(separator: " ").localizedCaseInsensitiveContains("password"))
    }

    func testInitializerClassifiesCancelledMacOSAuthorization() async {
        let initializer = XcodeCommandLineInitializer(runner: ProcessRunner { _, _, _, _, _ in
            ProcessResult(exitCode: 128, stdout: "", stderr: "User canceled")
        })

        do {
            try await initializer.initialize(
                applicationURL: URL(fileURLWithPath: "/Applications/IOSSim-Xcode.app"),
                userAcceptedLicense: true
            )
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .initializationAuthorizationCancelled)
        }
    }

    func testArtifactVerifierRejectsWrongPinnedBuildBeforeExecutingDownloadedCode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-wrong-xcode-build-\(UUID().uuidString)", isDirectory: true)
        let application = root.appendingPathComponent("Xcode.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: application.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.dt.Xcode",
            "CFBundleShortVersionString": "26.6",
            "DTXcodeBuild": "17F112"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: application.appendingPathComponent("Contents/Info.plist"))
        let versionData = try PropertyListSerialization.data(
            fromPropertyList: ["ProductBuildVersion": "WRONG"], format: .xml, options: 0
        )
        try versionData.write(to: application.appendingPathComponent("Contents/version.plist"))
        let calls = LockedCommandRecorder()
        let verifier = XcodeArtifactVerifier(runner: ProcessRunner { executable, arguments, _, _, _ in
            calls.append(executable.path, arguments)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        })

        do {
            try await verifier.verifyExtractedApplication(application)
            XCTFail("expected exact build rejection")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .xcodeIdentityInvalid)
        }
        XCTAssertTrue(calls.commands.isEmpty)
    }

    func testPrivilegedInstallerReportsCancelledSystemAuthorization() async throws {
        let source = URL(fileURLWithPath: "/tmp/Staged-Xcode.app")
        let destination = URL(fileURLWithPath: "/Applications/IOSSim-Xcode-test-\(UUID().uuidString).app")
        let installer = XcodePrivilegedInstaller(runner: ProcessRunner { _, arguments, _, _, _ in
            XCTAssertTrue(arguments.contains(source.path))
            XCTAssertTrue(arguments.contains(destination.path))
            return ProcessResult(exitCode: 128, stdout: "", stderr: "User canceled")
        })

        do {
            _ = try await installer.install(applicationURL: source, destinationURL: destination)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .installAuthorizationCancelled)
        }
    }

    func testStreamingDownloaderCompletesAndReportsProgress() async throws {
        let payload = Data("official-xip-fixture".utf8)
        StubURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(payload.count)]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: payload)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let progress = LockedProgressRecorder()
        let destination = temporaryDownloadURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let result = try await downloader().download(
            authorization: try authorization(),
            destinationURL: destination,
            requiredFreeSpace: 1,
            progress: { progress.append($0) }
        )

        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(progress.values.last?.completedBytes, Int64(payload.count))
    }

    func testStreamingDownloaderResumesFromPartialFileWithRange() async throws {
        let destination = temporaryDownloadURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: destination.appendingPathExtension("partial"))
        StubURLProtocol.handler = { protocolInstance in
            XCTAssertEqual(protocolInstance.request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            let tail = Data("def".utf8)
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(tail.count),
                    "Content-Range": "bytes 3-5/6"
                ]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: tail)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        _ = try await downloader().download(
            authorization: try authorization(),
            destinationURL: destination,
            requiredFreeSpace: 1,
            progress: { _ in }
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
    }

    func testStreamingDownloaderClassifiesAuthenticationFailure() async throws {
        StubURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        do {
            _ = try await downloader().download(
                authorization: try authorization(),
                destinationURL: temporaryDownloadURL(),
                requiredFreeSpace: 1,
                progress: { _ in }
            )
            XCTFail("expected authentication failure")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .authenticationRequired)
        }
    }

    func testStreamingDownloaderRejectsWrongResumeRangeAndResetsPartialFile() async throws {
        let destination = temporaryDownloadURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try Data("abc".utf8).write(to: partial)
        StubURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "3", "Content-Range": "bytes 0-2/6"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        do {
            _ = try await downloader().download(
                authorization: try authorization(),
                destinationURL: destination,
                requiredFreeSpace: 1,
                progress: { _ in }
            )
            XCTFail("expected invalid range")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .downloadIncomplete)
        }
        XCTAssertEqual(try Data(contentsOf: partial), Data())
    }

    func testStreamingDownloaderSurfacesNetworkLossAndKeepsPartialCheckpoint() async throws {
        let destination = temporaryDownloadURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        StubURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "20"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("partial".utf8))
            protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: URLError(.networkConnectionLost))
        }

        do {
            _ = try await downloader().download(
                authorization: try authorization(),
                destinationURL: destination,
                requiredFreeSpace: 1,
                progress: { _ in }
            )
            XCTFail("expected network loss")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStreamingDownloaderCancellationStopsRequestAndKeepsPartialCheckpoint() async throws {
        let destination = temporaryDownloadURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let started = expectation(description: "download started")
        let stopped = expectation(description: "download stopped")
        StubURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "20"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("partial".utf8))
            started.fulfill()
        }
        StubURLProtocol.onStop = { stopped.fulfill() }
        let operation = Task {
            try await downloader().download(
                authorization: try authorization(),
                destinationURL: destination,
                requiredFreeSpace: 1,
                progress: { _ in }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    func testDownloaderRejectsInsufficientDiskBeforeNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let downloader = AppleXcodeArchiveDownloader(configuration: configuration, capacityProvider: { _ in 10 })
        do {
            _ = try await downloader.download(
                authorization: try authorization(),
                destinationURL: temporaryDownloadURL(),
                requiredFreeSpace: 11,
                progress: { _ in }
            )
            XCTFail("expected disk failure")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .insufficientDiskSpace(required: 11, available: 10))
        }
    }

    func testInstallerRefusesToOverwriteExistingXcode() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("existing-xcode-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let calls = LockedCommandRecorder()
        let installer = XcodePrivilegedInstaller(runner: ProcessRunner { executable, arguments, _, _, _ in
            calls.append(executable.path, arguments)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        })

        do {
            _ = try await installer.install(
                applicationURL: URL(fileURLWithPath: "/tmp/Staged-Xcode.app"),
                destinationURL: destination
            )
            XCTFail("expected existing destination refusal")
        } catch {
            XCTAssertEqual(error as? XcodeBootstrapError, .installDestinationExists)
        }
        XCTAssertTrue(calls.commands.isEmpty)
    }

    private func downloader() -> AppleXcodeArchiveDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AppleXcodeArchiveDownloader(configuration: configuration, capacityProvider: { _ in .max })
    }

    private func authorization() throws -> EphemeralXcodeDownloadAuthorization {
        try EphemeralXcodeDownloadAuthorization(
            request: URLRequest(url: URL(string: "https://developer.apple.com/services-account/download")!)
        )
    }

    private func temporaryDownloadURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-download-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Xcode.xip")
    }
}

final class AutomaticRPPairingMacTests: XCTestCase {
    func testStructuralValidatorRejectsInvalidCandidate() {
        XCTAssertThrowsError(try MacRPPairingValidator.validate(Data("not pairing".utf8)))
    }

    func testCoordinatorRejectsStaleGenerationBeforeGenerating() async {
        let generator = FakePairingGenerator()
        let coordinator = AutomaticRPPairingCoordinator(generator: generator, transfer: FakePairingTransfer())
        do {
            _ = try await coordinator.prepare(
                selectedDeviceIdentifier: "phone-a",
                mainBundleIdentifier: "com.example.app",
                generation: 4,
                isCurrent: { _, _ in false }
            )
            XCTFail("expected stale operation")
        } catch {
            XCTAssertEqual(error as? AutomaticPairingError, .staleOperation)
        }
        let generationCount = await generator.count
        XCTAssertEqual(generationCount, 0)
    }

    func testCoordinatorRejectsWrongDeviceCandidateBeforeTransferAndDeletesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-wrong-device-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidateURL = root.appendingPathComponent("candidate.plist")
        try Data("secret".utf8).write(to: candidateURL)
        let transfer = CountingPairingTransfer()
        let coordinator = AutomaticRPPairingCoordinator(
            generator: FixedPairingGenerator(candidate: .init(
                transactionID: UUID(), selectedDeviceHash: "wrong-device", generation: 9, fileURL: candidateURL
            )),
            transfer: transfer
        )

        do {
            _ = try await coordinator.prepare(
                selectedDeviceIdentifier: "phone-a",
                mainBundleIdentifier: "com.example.app",
                generation: 9,
                isCurrent: { _, _ in true }
            )
            XCTFail("expected selected-device mismatch")
        } catch {
            XCTAssertEqual(error as? AutomaticPairingError, .staleOperation)
        }
        let transferCount = await transfer.count
        XCTAssertEqual(transferCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDevicectlTransferUsesPrivateContainerAndVerifiesReceipt() async throws {
        let transaction = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-pairing-transfer-\(transaction.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidateURL = root.appendingPathComponent("\(transaction.uuidString).plist")
        try Data("secret-candidate".utf8).write(to: candidateURL)
        let recorder = LockedCommandRecorder()
        let runner = ProcessRunner { executable, arguments, _, _, _ in
            recorder.append(executable.path, arguments)
            if arguments.starts(with: ["devicectl", "device", "copy", "from"]),
               let destinationIndex = arguments.firstIndex(of: "--destination") {
                let destination = URL(fileURLWithPath: arguments[destinationIndex + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let receipt = AutomaticPairingReceipt(transactionID: transaction, state: AutomaticPairingState.ready.rawValue)
                try JSONEncoder().encode(receipt).write(to: destination.appendingPathComponent("receipt.json"))
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let transfer = DevicectlRPPairingTransfer(runner: runner, receiptAttempts: 1)
        let candidate = RPPairingCandidate(
            transactionID: transaction,
            selectedDeviceHash: "hash",
            generation: 7,
            fileURL: candidateURL
        )

        let receipt = try await transfer.transferAndVerify(
            candidate: candidate,
            selectedDeviceIdentifier: "selected-phone",
            mainBundleIdentifier: "com.example.iossim"
        )

        XCTAssertEqual(receipt.state, AutomaticPairingState.ready.rawValue)
        let commands = recorder.commands.flatMap(\.arguments)
        XCTAssertTrue(commands.contains("appDataContainer"))
        XCTAssertFalse(commands.contains { $0.localizedCaseInsensitiveContains("Documents") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

private final class LockedCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(executable: String, arguments: [String])] = []

    var commands: [(executable: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ executable: String, _ arguments: [String]) {
        lock.lock()
        storage.append((executable, arguments))
        lock.unlock()
    }
}

private final class LockedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [XcodeDownloadProgress] = []

    var values: [XcodeDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: XcodeDownloadProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((StubURLProtocol) -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        handler(self)
    }

    override func stopLoading() { Self.onStop?() }
}

private actor FakePairingGenerator: RPPairingCandidateGenerating {
    private(set) var count = 0

    func generate(selectedDeviceIdentifier: String, generation: UInt64) async throws -> RPPairingCandidate {
        count += 1
        throw AutomaticPairingError.generationFailed
    }
}

private struct FakePairingTransfer: RPPairingMaterialTransferring {
    func transferAndVerify(
        candidate: RPPairingCandidate,
        selectedDeviceIdentifier: String,
        mainBundleIdentifier: String
    ) async throws -> AutomaticPairingReceipt {
        AutomaticPairingReceipt(transactionID: candidate.transactionID, state: AutomaticPairingState.ready.rawValue)
    }
}

private struct FixedPairingGenerator: RPPairingCandidateGenerating {
    let candidate: RPPairingCandidate

    func generate(selectedDeviceIdentifier: String, generation: UInt64) async throws -> RPPairingCandidate {
        candidate
    }
}

private actor CountingPairingTransfer: RPPairingMaterialTransferring {
    private(set) var count = 0

    func transferAndVerify(
        candidate: RPPairingCandidate,
        selectedDeviceIdentifier: String,
        mainBundleIdentifier: String
    ) async throws -> AutomaticPairingReceipt {
        count += 1
        return AutomaticPairingReceipt(transactionID: candidate.transactionID, state: AutomaticPairingState.ready.rawValue)
    }
}
