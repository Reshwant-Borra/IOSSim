import Foundation

@MainActor
public final class SetupStore: ObservableObject {
    @Published public private(set) var phase: SetupPhase = .welcome
    @Published public private(set) var status: DoctorStatus?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCriticalStage = false
    @Published public private(set) var completedInstallStages: Set<InstallStage> = []
    @Published public private(set) var lastError: SetupError?
    @Published public private(set) var logs: [EngineLogEntry] = []
    @Published public var selectedDeviceIdentifier: String?

    public let engine: any IOSSimSetupEngine
    private var task: Task<Void, Never>?
    private let onboardingKey = "IOSSimMac.onboardingCompleted"

    public init(engine: any IOSSimSetupEngine) {
        self.engine = engine
    }

    public var onboardingCompleted: Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }

    public func bootstrap() {
        guard task == nil else { return }
        if onboardingCompleted {
            phase = .checkingMac
            refresh()
        }
    }

    public func getStarted() {
        guard !isRunning else { return }
        phase = .checkingMac
        refresh()
    }

    public func refresh() {
        runCancellable(stage: .checkingMac) { [self] in
            let next = try await engine.doctor()
            status = next
            routeAfterDoctor(next)
        }
    }

    public func continueFromCurrentStatus() {
        guard let status, !isRunning else { return }
        if !status.mac.ready {
            runSetup()
            return
        }
        if status.provisioningReady {
            runProvisioning()
            return
        }
        phase = .checkingDevice
        refresh()
    }

    public func runRepair() {
        guard !isRunning else { return }
        phase = .checkingMac
        runCancellable(stage: .checkingMac) { [self] in
            let next = try await engine.doctor()
            status = next
            if !next.mac.ready {
                let result = try await engine.setup()
                logs.append(.init(stage: "setup", result: result))
            }
            if next.provisioningReady {
                try await runProvisioningBody()
            } else {
                routeAfterDoctor(next)
            }
        }
    }

    public func runUpdateComponents() {
        guard !isRunning else { return }
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] in
            let buildResult = try await engine.build()
            logs.append(.init(stage: "build", result: buildResult))
            completedInstallStages.insert(.installIOSSim)
            completedInstallStages.insert(.installRuntime)
            let deviceResult = try await engine.provisionDevice(selectedDeviceIdentifier: selectedDeviceIdentifier)
            logs.append(.init(stage: "device", result: deviceResult))
            completedInstallStages.insert(.verify)
            phase = .verifying
            let next = try await engine.doctor()
            status = next
            routeAfterDoctor(next)
        }
    }

    public func cancelCurrentOperation() {
        guard !isCriticalStage else { return }
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func showDashboard() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        phase = .complete
    }

    private func runSetup() {
        phase = .checkingMac
        runCritical { [self] in
            let result = try await engine.setup()
            logs.append(.init(stage: "setup", result: result))
            let next = try await engine.doctor()
            status = next
            routeAfterDoctor(next)
        }
    }

    private func runProvisioning() {
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] in
            try await runProvisioningBody()
        }
    }

    private func runProvisioningBody() async throws {
        completedInstallStages.insert(.installIOSSim)
        let result = try await engine.provisionDevice(selectedDeviceIdentifier: selectedDeviceIdentifier)
        logs.append(.init(stage: "device", result: result))
        completedInstallStages.insert(.installRuntime)
        phase = .verifying
        let next = try await engine.doctor()
        status = next
        completedInstallStages.insert(.verify)
        routeAfterDoctor(next)
    }

    private func routeAfterDoctor(_ status: DoctorStatus) {
        if status.device.devices.count == 1 {
            selectedDeviceIdentifier = status.device.devices[0].identifier
        } else if status.device.devices.count > 1 {
            let knownIdentifiers = Set(status.device.devices.map(\.identifier))
            if selectedDeviceIdentifier.map({ !knownIdentifiers.contains($0) }) ?? true {
                selectedDeviceIdentifier = status.device.devices[0].identifier
            }
        } else if status.device.devices.isEmpty {
            selectedDeviceIdentifier = nil
        }
        if status.setupCompleteForDashboard || onboardingCompleted {
            phase = .complete
            return
        }
        if !status.mac.ready {
            phase = .macActionRequired
            return
        }
        switch StatusInterpreter.deviceReadiness(from: status) {
        case .noDevice, .multipleDevices:
            phase = .waitingForDevice
        case .trustRequired, .developerModeRequired:
            phase = .deviceActionRequired
        case .readyForInstall:
            phase = .installing
        case .localDevVPNRequired, .pairingRequired:
            phase = .runtimeSetup
        case .complete:
            phase = .complete
            UserDefaults.standard.set(true, forKey: onboardingKey)
        }
    }

    private func runCancellable(stage: SetupPhase, operation: @escaping @MainActor () async throws -> Void) {
        run(stage: stage, critical: false, operation: operation)
    }

    private func runCritical(operation: @escaping @MainActor () async throws -> Void) {
        run(stage: phase, critical: true, operation: operation)
    }

    private func run(stage: SetupPhase, critical: Bool, operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        phase = stage
        isRunning = true
        isCriticalStage = critical
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
            } catch is CancellationError {
                self.lastError = nil
            } catch let failure as ProcessFailure {
                self.lastError = Self.friendlyError(commandName: failure.commandName, result: failure.result)
                self.logs.append(.init(stage: failure.commandName, result: failure.result))
                self.phase = .failed
            } catch {
                self.lastError = SetupError(
                    headline: "IOSSim could not complete this step.",
                    recovery: "Check your setup and try again.",
                    details: Redactor.redact(String(describing: error))
                )
                self.phase = .failed
            }
            self.isRunning = false
            self.isCriticalStage = false
            self.task = nil
        }
    }

    private static func friendlyError(commandName: String, result: ProcessResult) -> SetupError {
        let lower = result.combinedOutput.lowercased()
        if lower.contains("locked") {
            return SetupError(
                headline: "IOSSim could not install on this iPhone.",
                recovery: "Unlock your iPhone and try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("developer mode") {
            return SetupError(
                headline: "Developer Mode is required.",
                recovery: "Enable Developer Mode on your iPhone, then try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("development team") || lower.contains("signing") {
            return SetupError(
                headline: "Apple signing needs attention.",
                recovery: "Open Xcode Settings and make sure an Apple Development account is available.",
                details: result.combinedOutput
            )
        }
        if lower.contains("bundled runtime damaged") || lower.contains("bundled artifact") || lower.contains("artifact manifest") {
            return SetupError(
                headline: "Bundled runtime damaged.",
                recovery: "Required IOSSim components are missing from this application. Reinstall IOSSim.",
                details: result.combinedOutput
            )
        }
        if lower.contains("apple development support required") || lower.contains("devicectl") || lower.contains("xcrun") {
            return SetupError(
                headline: "Apple development support required.",
                recovery: "Install or select Apple's developer tools required for iPhone discovery and app installation.",
                details: result.combinedOutput
            )
        }
        if lower.contains("permission denied") || result.exitCode == 126 {
            return SetupError(
                headline: "IOSSim could not start its setup helper.",
                recovery: "The development helper could not be launched. Open Diagnostics for the executable and repository checks.",
                details: result.combinedOutput.isEmpty ? "Exit code \(result.exitCode)" : result.combinedOutput
            )
        }
        return SetupError(
            headline: "IOSSim could not complete \(commandName).",
            recovery: "Try again after addressing the details below.",
            details: result.combinedOutput.isEmpty ? "Exit code \(result.exitCode)" : result.combinedOutput
        )
    }
}
