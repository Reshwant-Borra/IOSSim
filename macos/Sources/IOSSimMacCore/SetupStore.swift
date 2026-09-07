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
    @Published public private(set) var selectedDeviceIdentifier: String?
    @Published public private(set) var deviceSelectionReason: DeviceSelectionReason = .noConnectedDevices
    @Published public private(set) var personalTeams: [PersonalTeamCandidate] = []
    @Published public private(set) var selectedTeamIdentifier: String?
    @Published public private(set) var provisioningManifest: ConsumerProvisioningManifest?
    @Published public private(set) var consumerStage: ConsumerProvisioningStage = .idle
    @Published public private(set) var lastSupportBundleURL: URL?
    @Published public private(set) var appleAuthorization = AppleAuthorizationSummary(
        method: .privateGrandSlamSRP,
        stage: .notStarted,
        sessionValid: false
    )
    @Published public private(set) var appleVerificationChallenge: AppleVerificationChallenge?

    public let engine: any IOSSimSetupEngine
    private let authorizationCoordinator: ExperimentalConsumerProvisioningCoordinator
    private var task: Task<Void, Never>?
    private let onboardingKey = "IOSSimMac.onboardingCompleted"
    private let selectedDeviceKey = "IOSSimMac.selectedDeviceIdentifier"
    private let selectedDeviceNameKey = "IOSSimMac.selectedDeviceName"
    private let selectedTeamKey = "IOSSimMac.selectedPersonalTeam"
    private let automaticRefreshKey = "IOSSimMac.automaticRefreshEnabled"
    private var automaticRefreshAttempted = false

    public init(
        engine: any IOSSimSetupEngine,
        authorizationCoordinator: ExperimentalConsumerProvisioningCoordinator = .init(
            backend: UnavailableExperimentalPersonalTeamBackend()
        )
    ) {
        self.engine = engine
        self.authorizationCoordinator = authorizationCoordinator
        selectedDeviceIdentifier = UserDefaults.standard.string(forKey: selectedDeviceKey)
        selectedTeamIdentifier = UserDefaults.standard.string(forKey: selectedTeamKey)
    }

    public var onboardingCompleted: Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }

    public var selectedDevice: DetectedDevice? {
        guard let selectedDeviceIdentifier else { return nil }
        return status?.device.devices.first { $0.selectionIdentifier == selectedDeviceIdentifier }
    }

    public var selectedDeviceProvisioningReady: Bool {
        selectedDevice.map {
            $0.pairingState == "paired" && $0.developerModeStatus == "enabled" && $0.isLocked != true
        } ?? false
    }

    public var deviceSelectionRequired: Bool {
        guard let status else { return false }
        if status.device.devices.count > 1, selectedDeviceIdentifier == nil {
            return true
        }
        return DeviceSelectionPolicy.resolve(
            devices: status.device.devices,
            rememberedIdentifier: UserDefaults.standard.string(forKey: selectedDeviceKey),
            rememberedName: UserDefaults.standard.string(forKey: selectedDeviceNameKey)
        ).selectionRequired
    }

    public var disconnectedDeviceName: String? {
        guard case .rememberedDeviceDisconnected = deviceSelectionReason else { return nil }
        return UserDefaults.standard.string(forKey: selectedDeviceNameKey)
    }

    public var selectedTeam: PersonalTeamCandidate? {
        guard let selectedTeamIdentifier else { return nil }
        return personalTeams.first { $0.teamIdentifier == selectedTeamIdentifier }
    }

    public var refreshDueState: RefreshDueState {
        ConsumerRefreshPolicy.recommended.dueState(expiration: provisioningManifest?.earliestExpiration)
    }

    public var automaticRefreshEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: automaticRefreshKey) == nil
                || UserDefaults.standard.bool(forKey: automaticRefreshKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticRefreshKey) }
    }

    public func bootstrap() {
        guard task == nil else { return }
        if onboardingCompleted {
            phase = .checkingMac
            refresh()
            Task { [weak self] in
                guard let self else { return }
                while self.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                self.runAutomaticRefreshIfDue()
            }
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
            applyDeviceSelection(from: next)
            try await updateConsumerContext()
            routeAfterDoctor(next)
        }
    }

    public func continueFromCurrentStatus() {
        guard let status, !isRunning else { return }
        if !status.mac.ready {
            runSetup()
            return
        }
        if selectedDeviceProvisioningReady {
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
            applyDeviceSelection(from: next)
            try await updateConsumerContext()
            if selectedDeviceProvisioningReady {
                try await runProvisioningBody(operation: .repair)
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
            if engine.consumerProvisioningEnabled {
                try await runProvisioningBody(operation: .refresh)
                return
            }
            let buildResult = try await engine.build()
            logs.append(.init(stage: "build", result: buildResult))
            completedInstallStages.insert(.installIOSSim)
            completedInstallStages.insert(.installRuntime)
            let deviceResult = try await engine.provisionDevice(selectedDeviceIdentifier: try selectedDeviceIdentifierForOperation())
            logs.append(.init(stage: "device", result: deviceResult))
            completedInstallStages.insert(.verify)
            phase = .verifying
            let next = try await engine.doctor()
            status = next
            routeAfterDoctor(next)
        }
    }

    public func runConfirmedFreshInstall() {
        guard !isRunning else { return }
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] in
            try await runProvisioningBody(operation: .install, allowFreshInstall: true)
        }
    }

    public func exportSupportBundle() {
        guard !isRunning else { return }
        runCancellable(stage: phase) { [self] in
            lastSupportBundleURL = try await engine.exportSupportBundle()
        }
    }

    public func setAutomaticRefreshEnabled(_ enabled: Bool) {
        automaticRefreshEnabled = enabled
    }

    private func runAutomaticRefreshIfDue() {
        guard !automaticRefreshAttempted,
              automaticRefreshEnabled,
              [.dueNow, .expired].contains(refreshDueState),
              selectedDevice != nil,
              selectedTeam != nil else { return }
        automaticRefreshAttempted = true
        runUpdateComponents()
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

    public func confirmRuntimeSetup() {
        guard !isRunning else { return }
        runCancellable(stage: .verifying) { [self] in
            if engine.consumerProvisioningEnabled {
                guard consumerProvisioningStateSupportsRuntimeSetup else {
                    throw ConsumerProvisioningFailure(
                        code: .runnerMappingMissing,
                        stage: .verifyingRuntimeReadiness,
                        userMessage: "IOSSim installation information is missing.",
                        remediation: "Complete IOSSim installation before finishing iPhone setup.",
                        developerDetail: "Runtime setup requires a valid provisioning manifest and deterministic runner mapping."
                    )
                }
                provisioningManifest = try await engine.confirmRuntimeSetup()
            }
            UserDefaults.standard.set(true, forKey: onboardingKey)
            let next = try await engine.doctor()
            status = next
            phase = .complete
        }
    }

    public func selectDevice(identifier: String) {
        guard let status,
              let device = status.device.devices.first(where: { $0.selectionIdentifier == identifier }) else {
            selectedDeviceIdentifier = nil
            return
        }
        selectedDeviceIdentifier = device.selectionIdentifier
        deviceSelectionReason = .rememberedDeviceConnected
        UserDefaults.standard.set(device.selectionIdentifier, forKey: selectedDeviceKey)
        UserDefaults.standard.set(device.name, forKey: selectedDeviceNameKey)
    }

    public func selectTeam(identifier: String) {
        guard personalTeams.contains(where: { $0.teamIdentifier == identifier }) else {
            selectedTeamIdentifier = nil
            return
        }
        selectedTeamIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: selectedTeamKey)
    }

    /// Accepts the SwiftUI `String` only at this boundary. The view clears its
    /// bindings immediately; this method converts the password to wipeable
    /// bytes before starting asynchronous work and never stores it in state.
    public func beginAppleAuthorization(account: String, password: String) {
        guard !isRunning, !account.isEmpty, !password.isEmpty else { return }
        let sensitivePassword = SensitiveInput(password)
        runCancellable(stage: .appleAccount) { [self] in
            appleVerificationChallenge = try await authorizationCoordinator.begin(
                account: account,
                password: sensitivePassword
            )
            appleAuthorization = await authorizationCoordinator.authorization
            if appleVerificationChallenge == nil {
                try await applyExperimentalTeams()
            }
        }
    }

    public func submitAppleVerification(code: String) {
        guard !isRunning, !code.isEmpty else { return }
        let sensitiveCode = SensitiveInput(code)
        runCancellable(stage: .appleAccount) { [self] in
            appleVerificationChallenge = try await authorizationCoordinator.verify(code: sensitiveCode)
            appleAuthorization = await authorizationCoordinator.authorization
            if appleVerificationChallenge == nil {
                try await applyExperimentalTeams()
            }
        }
    }

    private func applyExperimentalTeams() async throws {
        let discovered = await authorizationCoordinator.teams
        guard !discovered.isEmpty else { throw ExperimentalBackendError.noTeam }
        personalTeams = discovered.map {
            PersonalTeamCandidate(
                teamIdentifier: $0.id,
                teamDisplayName: $0.name,
                signingIdentityCommonName: "IOSSim managed",
                signingIdentityFingerprint: "pending",
                certificateSubjectTeamIdentifier: $0.id,
                personalTeam: $0.isPersonalTeam
            )
        }
        if let preferred = try? ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: discovered) {
            selectTeam(identifier: preferred.id)
        }
        phase = .installing
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
            try await runProvisioningBody(operation: .install)
        }
    }

    private func runProvisioningBody(
        operation: ConsumerProvisioningOperation,
        allowFreshInstall: Bool = false
    ) async throws {
        if engine.consumerProvisioningEnabled {
            let device = try selectedDeviceIdentifierForOperation()
            guard let team = selectedTeamIdentifier else {
                throw ConsumerProvisioningFailure(
                    code: .teamSelectionRequired,
                    stage: .waitingForTeamSelection,
                    userMessage: "IOSSim couldn't prepare Apple authorization.",
                    remediation: "Continue Apple authorization in IOSSim, then try again.",
                    developerDetail: "No Personal Team selected."
                )
            }
            consumerStage = .preparingIdentities
            let result = try await engine.consumerProvision(ConsumerProvisioningRequest(
                operation: operation,
                selectedDeviceIdentifier: device,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: allowFreshInstall
            ))
            provisioningManifest = result.manifest
            consumerStage = result.finalStage
            completedInstallStages = Set(InstallStage.allCases)
            phase = .runtimeSetup
            return
        }
        completedInstallStages.insert(.installIOSSim)
        let result = try await engine.provisionDevice(selectedDeviceIdentifier: try selectedDeviceIdentifierForOperation())
        logs.append(.init(stage: "device", result: result))
        completedInstallStages.insert(.installRuntime)
        phase = .verifying
        let next = try await engine.doctor()
        status = next
        completedInstallStages.insert(.verify)
        routeAfterDoctor(next)
    }

    private func routeAfterDoctor(_ status: DoctorStatus) {
        let installationKnown = !engine.consumerProvisioningEnabled || consumerProvisioningStateSupportsRuntimeSetup
        let consumerRuntimeReady = !engine.consumerProvisioningEnabled
            || (consumerProvisioningStateSupportsRuntimeSetup && provisioningManifest?.runtimeSetupStatus == .ready)
        if (status.mac.ready && selectedDeviceProvisioningReady && status.runtimeActionChecks.isEmpty && installationKnown)
            || (onboardingCompleted && consumerRuntimeReady) {
            phase = .complete
            return
        }
        if !status.mac.ready {
            phase = .macActionRequired
            return
        }
        if engine.consumerProvisioningEnabled,
           selectedDeviceProvisioningReady,
           !consumerProvisioningStateSupportsRuntimeSetup {
            routeToConsumerProvisioning()
            return
        }
        switch StatusInterpreter.deviceReadiness(from: status) {
        case .noDevice, .multipleDevices:
            phase = .waitingForDevice
        case .trustRequired, .developerModeRequired, .unlockRequired:
            phase = .deviceActionRequired
        case .readyForInstall:
            routeToConsumerProvisioning()
        case .localDevVPNRequired, .pairingRequired:
            phase = .runtimeSetup
        case .complete:
            phase = .complete
            UserDefaults.standard.set(true, forKey: onboardingKey)
        }
    }

    private var consumerProvisioningStateSupportsRuntimeSetup: Bool {
        guard let manifest = provisioningManifest,
              manifest.schemaVersion == ConsumerProvisioningManifest.currentSchemaVersion,
              !manifest.teamID.isEmpty,
              let expected = try? PersonalTeamBundleIdentifierSet(teamIdentifier: manifest.teamID) else {
            return false
        }
        let source = ProtectedSourceBundleIdentifiers.default
        return manifest.sourceMainBundleID == source.main
            && manifest.installedMainBundleID == expected.main
            && manifest.sourceUITestBundleID == source.uiTests
            && manifest.installedUITestBundleID == expected.uiTests
            && manifest.sourceRunnerBundleID == source.runner
            && manifest.installedRunnerBundleID == expected.runner
            && manifest.mainProfile.teamIdentifier == manifest.teamID
            && manifest.mainProfile.bundleIdentifier == expected.main
            && manifest.runnerProfile.teamIdentifier == manifest.teamID
            && manifest.runnerProfile.bundleIdentifier == expected.runner
    }

    private func routeToConsumerProvisioning() {
        if engine.consumerProvisioningEnabled && (personalTeams.isEmpty || selectedTeam == nil) {
            phase = .appleAccount
        } else {
            phase = .installing
        }
    }

    private func updateConsumerContext() async throws {
        guard engine.consumerProvisioningEnabled else { return }
        provisioningManifest = try await engine.consumerProvisioningStatus()
        guard let selectedDeviceIdentifier else {
            personalTeams = []
            selectedTeamIdentifier = nil
            return
        }
        personalTeams = try await engine.discoverPersonalTeams(selectedDeviceIdentifier: selectedDeviceIdentifier)
        let remembered = UserDefaults.standard.string(forKey: selectedTeamKey)
        if let remembered, personalTeams.contains(where: { $0.teamIdentifier == remembered }) {
            selectedTeamIdentifier = remembered
        } else if personalTeams.filter(\.personalTeam).count == 1,
                  let personal = personalTeams.first(where: \.personalTeam) {
            selectTeam(identifier: personal.teamIdentifier)
        } else if personalTeams.count == 1 {
            selectTeam(identifier: personalTeams[0].teamIdentifier)
        } else if let manifest = provisioningManifest,
                  personalTeams.contains(where: { $0.teamIdentifier == manifest.teamID }) {
            selectTeam(identifier: manifest.teamID)
        } else {
            selectedTeamIdentifier = nil
        }
    }

    private func applyDeviceSelection(from status: DoctorStatus) {
        let remembered = UserDefaults.standard.string(forKey: selectedDeviceKey)
        let rememberedName = UserDefaults.standard.string(forKey: selectedDeviceNameKey)
        let result = DeviceSelectionPolicy.resolve(
            devices: status.device.devices,
            rememberedIdentifier: remembered,
            rememberedName: rememberedName
        )
        selectedDeviceIdentifier = result.selectedIdentifier
        deviceSelectionReason = result.reason
        if let selectedDevice = status.device.devices.first(where: { $0.selectionIdentifier == result.selectedIdentifier }) {
            UserDefaults.standard.set(selectedDevice.selectionIdentifier, forKey: selectedDeviceKey)
            UserDefaults.standard.set(selectedDevice.name, forKey: selectedDeviceNameKey)
        }
    }

    private func selectedDeviceIdentifierForOperation() throws -> String {
        guard let status else {
            throw selectionFailure("DEVICE_SELECTION_REQUIRED: refresh device status before provisioning.")
        }
        let liveMatches = status.device.devices.filter { $0.selectionIdentifier == selectedDeviceIdentifier }
        guard let selected = liveMatches.first, liveMatches.count == 1 else {
            if status.device.devices.isEmpty {
                let name = UserDefaults.standard.string(forKey: selectedDeviceNameKey) ?? "this iPhone"
                throw selectionFailure("IPHONE_DISCONNECTED: Reconnect \(name) or choose another device.")
            }
            throw selectionFailure("DEVICE_SELECTION_REQUIRED: choose one connected iPhone before provisioning.")
        }
        return selected.selectionIdentifier
    }

    private func selectionFailure(_ message: String) -> ProcessFailure {
        ProcessFailure(
            commandName: "device-selection",
            result: ProcessResult(exitCode: 2, stdout: "", stderr: message)
        )
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
            } catch let failure as ConsumerProvisioningFailure {
                self.lastError = SetupError(
                    headline: failure.userMessage,
                    recovery: failure.remediation,
                    details: "\(failure.code.rawValue): \(failure.developerDetail)"
                )
                self.consumerStage = .failed
                self.phase = .failed
            } catch let failure as ExperimentalBackendError {
                self.appleAuthorization = await self.authorizationCoordinator.authorization
                self.lastError = Self.appleAuthorizationError(failure)
                self.phase = failure == .verificationExpired ? .appleAccount : .failed
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

    private static func appleAuthorizationError(_ failure: ExperimentalBackendError) -> SetupError {
        switch failure {
        case .badPassword:
            return SetupError(
                headline: "Apple couldn't verify that account.",
                recovery: "Check your Apple Account and password, then try again.",
                details: failure.safeCode
            )
        case .verificationExpired:
            return SetupError(
                headline: "That Apple verification code expired.",
                recovery: "Request or enter a new verification code.",
                details: failure.safeCode
            )
        case .sessionExpired:
            return SetupError(
                headline: "Apple authorization needs to be refreshed.",
                recovery: "Continue with Apple to authorize IOSSim again.",
                details: failure.safeCode
            )
        default:
            return SetupError(
                headline: "IOSSim couldn't prepare Apple authorization.",
                recovery: "Try again. IOSSim will not change your other development certificates or apps.",
                details: failure.safeCode
            )
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
        if lower.contains("iphone_disconnected") || lower.contains("iphone disconnected") {
            return SetupError(
                headline: "iPhone Disconnected",
                recovery: "Reconnect the selected iPhone or choose another device.",
                details: result.combinedOutput
            )
        }
        if lower.contains("device_selection_required") {
            return SetupError(
                headline: "Choose an iPhone",
                recovery: "Select the connected iPhone you want IOSSim to set up, then try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("device_not_in_profile") || lower.contains("artifact_eligibility") {
            return SetupError(
                headline: "This iPhone is not authorized for this IOSSim build.",
                recovery: "Use an iPhone included in the bundled provisioning profile or create a new signed build for this device.",
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
                headline: "IOSSim couldn't prepare Apple authorization.",
                recovery: "Continue Apple authorization in IOSSim, then try again.",
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
